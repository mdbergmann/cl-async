(in-package :cl-async)

(define-condition event-freed (event-error)
  ((event :initarg :event :accessor event-freed-event :initform nil))
  (:report (lambda (c s) (format s "Freed event being operated on: ~a~%" c)))
  (:documentation "Thrown when a freed event is operated on."))

(defclass event ()
  ((c :accessor event-c :initarg :c :initform (cffi:null-pointer))
   (freed :accessor event-freed :reader event-freed-p :initform nil))
  (:documentation "Wraps a C libevent event object."))

(defun check-event-unfreed (event)
  "Checks that an event being operated on is not freed."
  (when (event-freed event)
    (error 'event-freed :event event)))

(defun free-event (event)
  "Free a cl-async event object and any resources it uses."
  (check-event-unfreed event)
  (let ((timer-c (event-c event)))
    (uv:uv-timer-stop timer-c)
    (uv:free-handle timer-c))
  (setf (event-freed event) t))

(defun remove-event (event)
  "Remove a pending event from the event loop."
  (check-event-unfreed event)
  (let ((timer-c (event-c event)))
    (uv:uv-timer-stop timer-c))
  t)

(defun add-event (event &key timeout activate)
  "Add an event to its specified event loop (make it pending). If given a
   :timeout (in seconds) the event will fire after that amount of time, unless
   it's removed or freed. If :activate is true and the event has no timeout,
   the event will be activated directly without being added to the event loop,
   and its callback(s) will be fired."
  (check-event-unfreed event)
  (let ((timer-c (event-c event)))
    (uv:uv-timer-start timer-c (cffi:callback timer-cb) (round (* (or timeout 0) 1000)) 0)))

(define-c-callback timer-cb :void ((timer-c :pointer))
  "Callback used by the async timer system to find and run user-specified
   callbacks on timer events."
  (declare (ignore fd what))
  (let* ((event (deref-data-from-pointer timer-c))
         (callbacks (get-callbacks timer-c))
         (cb (getf callbacks :callback))
         (event-cb (getf callbacks :event-cb)))
    (catch-app-errors event-cb
      (unwind-protect
        (when cb (funcall cb))
        (free-event event)))))

#|
(define-c-callback fd-cb :void ((poller :int) (status :int) (events :int))
  "Called when an event watching a file descriptor is triggered."
  (declare (ignore fd))
  (let* (;(event (deref-data-from-pointer data-pointer))
         (callbacks (get-callbacks data-pointer))
         (timeout-cb (getf callbacks :timeout-cb))
         (read-cb (getf callbacks :read-cb))
         (write-cb (getf callbacks :write-cb))
         (event-cb (getf callbacks :event-cb)))
    (catch-app-errors event-cb
      (when (and (< 0 (logand what le:+ev-read+))
                 read-cb)
         (funcall read-cb))
      (when (and (< 0 (logand what le:+ev-write+))
                 write-cb)
        (funcall write-cb))
      (when (and (< 0 (logand what le:+ev-timeout+))
                 timeout-cb)
         (funcall timeout-cb)))))
|#

(defun delay (callback &key time event-cb)
  "Run a function, asynchronously, after the specified amount of seconds. An
   event loop must be running for this to work.
   
   If time is nil, callback is still called asynchronously, but is queued in the
   event loop with no delay."
  (check-event-loop-running)
  (let* ((timer-c (uv:alloc-handle :timer))
         (event (make-instance 'event :c timer-c)))
    (uv:uv-timer-init (event-base-c *event-base*) timer-c)
    (save-callbacks timer-c (list :callback callback :event-cb event-cb))
    (attach-data-to-pointer timer-c event)
    (add-event event :timeout time :activate t)
    event))

(defmacro with-delay ((seconds) &body body)
  "Nicer syntax for delay function."
  `(delay (lambda () ,@body) :time ,seconds))

(defun interval (callback &key time event-cb)
  "Run a function, asynchronously, every `time` seconds. This function returns a
   function which, when called, cancels the interval."
  ;; TODO: convert to uv-timer w/repeat
  (let (event)
    (labels ((main ()
               (funcall callback)
               (when event
                 (setf event (as:delay #'main :time time :event-cb event-cb)))))
      (setf event (as:delay #'main :time time :event-cb event-cb))
      (lambda ()
        (remove-event event)
        (setf event nil)))))

(defmacro with-interval ((seconds) &body body)
  "Nicer syntax for interval function."
  `(interval (lambda () ,@body) :time ,seconds))

(defun remove-interval (interval-fn)
  "Stops an interval from looping."
  (funcall interval-fn))

(defun make-event (callback &key event-cb)
  "Make an arbitrary event, and add it to the event loop. It *must* be triggered
   by (add-event <the event> :activate t) or it will sit, idle, for 100 years.
   Or you can remove/free it instead.

   This is useful for triggering arbitrary events, and can even be triggered
   from a thread outside the libevent loop."
  (delay callback :event-cb event-cb :time (* 100 31536000)))

#|
(defun watch-fd (fd &key event-cb read-cb write-cb timeout-cb timeout)
  "Run a function, asynchronously, when the specified file descriptor is
   ready for write or read operations. An event loop must be running for
   this to work."
  (check-event-loop-running)
  ;; TODO: see uv_poll
  (let* ((data-pointer (create-data-pointer))
         (ev (le:event-new (event-base-c *event-base*)
                           fd
                           ;; listen to read/timeout events, and keep listening
                           (logior
                             (if timeout-cb le:+ev-timeout+ 0)
                             (if read-cb le:+ev-read+ 0)
                             (if write-cb le:+ev-write+ 0)
                             le:+ev-persist+)
                           (cffi:callback fd-cb)
                           data-pointer))
         (event (make-instance 'event
                               :c ev
                               :free-callback (lambda (event)
                                                (declare (ignore event))
                                                (free-pointer-data data-pointer)))))
    (save-callbacks data-pointer (list :read-cb read-cb
                                       :write-cb write-cb
                                       :timeout-cb timeout-cb
                                       :event-cb event-cb))
    (attach-data-to-pointer data-pointer event)
    (add-event event :timeout timeout)
    event))
|#
