;;;; X86-64-specific runtime stuff

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")
(defun machine-type ()
  "Return a string describing the type of the local machine."
  "X86-64")

;;;; :CODE-OBJECT fixups

;;; This gets called by LOAD to resolve newly positioned objects
;;; with things (like code instructions) that have to refer to them.
;;; Return :ABSOLUTE if an absolute fixup needs to be recorded in %CODE-FIXUPS,
;;; and return :RELATIVE if a relative fixup needs to be recorded.
;;; The code object we're fixing up is pinned whenever this is called.
(defun fixup-code-object (code offset fixup kind flavor)
  (declare (type index offset) (ignorable flavor))
  (let* ((sap (code-instructions code))
         (fixup (+ (if (eq kind :absolute64)
                       (signed-sap-ref-64 sap offset)
                       (signed-sap-ref-32 sap offset))
                   fixup)))
    (ecase kind
        (:absolute64
         ;; Word at sap + offset contains a value to be replaced by
         ;; adding that value to fixup.
         (setf (sap-ref-64 sap offset) fixup))
        (:absolute
         ;; Word at sap + offset contains a value to be replaced by
         ;; adding that value to fixup.
         (setf (sap-ref-32 sap offset) fixup))
        (:relative
         ;; Fixup is the actual address wanted.
         ;; Replace word with value to add to that loc to get there.
         ;; In the #-immobile-code case, there's nothing to assert.
         ;; Relative fixups pretty much can't happen.
         #+immobile-code
         (unless (immobile-space-obj-p code)
           (error "Can't compute fixup relative to movable object ~S" code))
         (setf (signed-sap-ref-32 sap offset)
               (etypecase fixup
                 (integer
                  ;; JMP/CALL are relative to the next instruction,
                  ;; so add 4 bytes for the size of the displacement itself.
                  (- fixup
                     (the (unsigned-byte 64) (+ (sap-int sap) offset 4)))))))))
  ;; An absolute fixup is stored in the code header's %FIXUPS slot if it
  ;; references an immobile-space (but not static-space) object.
  ;; Note that:
  ;;  (1) Call fixups occur in both :RELATIVE and :ABSOLUTE kinds.
  ;;      We can ignore the :RELATIVE kind, except for foreign call.
  ;;  (2) :STATIC-CALL fixups point to immobile space, not static space.
  #+immobile-space
  (return-from fixup-code-object
    (case flavor
      ((:named-call :layout :immobile-object ; -> fixedobj subspace
        :assembly-routine :assembly-routine* :static-call) ; -> varyobj subspace
       (if (eq kind :absolute) :absolute))
      (:foreign
       ;; linkage-table calls using the "CALL rel32" format need to be saved,
       ;; because the linkage table resides at a fixed address.
       ;; Space defragmentation can handle the fixup automatically,
       ;; but core relocation can't - it can't find all the call sites.
       (if (eq kind :relative) :relative))))
  nil) ; non-immobile-space builds never record code fixups

#+(or darwin linux openbsd win32)
(define-alien-routine ("os_context_float_register_addr" context-float-register-addr)
  (* unsigned) (context (* os-context-t)) (index int))

;;; This is like CONTEXT-REGISTER, but returns the value of a float
;;; register. FORMAT is the type of float to return.

(defun context-float-register (context index format)
  (declare (ignorable context index))
  #-(or darwin linux openbsd win32)
  (progn
    (warn "stub CONTEXT-FLOAT-REGISTER")
    (coerce 0 format))
  #+(or darwin linux openbsd win32)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (sap-ref-single sap 0))
      (double-float
       (sap-ref-double sap 0))
      (complex-single-float
       (complex (sap-ref-single sap 0)
                (sap-ref-single sap 4)))
      (complex-double-float
       (complex (sap-ref-double sap 0)
                (sap-ref-double sap 8))))))

(defun %set-context-float-register (context index format value)
  (declare (ignorable context index format))
  #-(or linux win32)
  (progn
    (warn "stub %SET-CONTEXT-FLOAT-REGISTER")
    value)
  #+(or linux win32)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (setf (sap-ref-single sap 0) value))
      (double-float
       (setf (sap-ref-double sap 0) value))
      (complex-single-float
       (locally
           (declare (type (complex single-float) value))
         (setf (sap-ref-single sap 0) (realpart value)
               (sap-ref-single sap 4) (imagpart value))))
      (complex-double-float
       (locally
           (declare (type (complex double-float) value))
         (setf (sap-ref-double sap 0) (realpart value)
               (sap-ref-double sap 8) (imagpart value)))))))

;;; Given a signal context, return the floating point modes word in
;;; the same format as returned by FLOATING-POINT-MODES.
#-linux
(defun context-floating-point-modes (context)
  (declare (ignore context)) ; stub!
  (warn "stub CONTEXT-FLOATING-POINT-MODES")
  0)
#+linux
(define-alien-routine ("os_context_fp_control" context-floating-point-modes)
    (unsigned 32)
  (context (* os-context-t)))

(define-alien-routine
    ("arch_get_fp_modes" floating-point-modes) (unsigned 32))

(define-alien-routine
    ("arch_set_fp_modes" %floating-point-modes-setter) void (fp (unsigned 32)))

(defun (setf floating-point-modes) (val) (%floating-point-modes-setter val))


;;;; INTERNAL-ERROR-ARGS

;;; Given a (POSIX) signal context, extract the internal error
;;; arguments from the instruction stream.
(defun internal-error-args (context)
  (declare (type (alien (* os-context-t)) context))
  (let* ((pc (context-pc context))
         (trap-number (sap-ref-8 pc 0)))
    (declare (type system-area-pointer pc))
    (if (= trap-number invalid-arg-count-trap)
        (values #.(error-number-or-lose 'invalid-arg-count-error)
                '(#.arg-count-sc))
        (sb-kernel::decode-internal-error-args (sap+ pc 1) trap-number))))


#+immobile-code
(progn
(defconstant trampoline-entry-offset n-word-bytes)
(defun fun-immobilize (fun)
  (let ((code (truly-the (values code-component &optional)
                         (sb-vm::alloc-immobile-trampoline))))
    (setf (%code-debug-info code) fun)
    (let ((sap (sap+ (code-instructions code) trampoline-entry-offset))
          (ea (+ (logandc2 (get-lisp-obj-address code) lowtag-mask)
                 (ash code-debug-info-slot word-shift))))
      ;; For a funcallable-instance, the instruction sequence is:
      ;;    MOV RAX, [RIP-n] ; load the function
      ;;    MOV RAX, [RAX+5] ; load the funcallable-instance-fun
      ;;    JMP [RAX-3]
      ;; Otherwise just instructions 1 and 3 will do.
      ;; We could use the #xA1 opcode to save a byte, but that would
      ;; be another headache do deal with when relocating this code.
      ;; There's precedent for this style of hand-assembly,
      ;; in arch_write_linkage_table_entry() and arch_do_displaced_inst().
      (setf (sap-ref-32 sap 0) #x058B48 ; REX MOV [RIP-n]
            (signed-sap-ref-32 sap 3) (- ea (+ (sap-int sap) 7))) ; disp
      (let ((i (if (/= (fun-subtype fun) funcallable-instance-widetag)
                   7
                   (let ((disp8 (- (ash funcallable-instance-function-slot
                                        word-shift)
                                   fun-pointer-lowtag))) ; = 5
                     (setf (sap-ref-32 sap 7) (logior (ash disp8 24) #x408B48))
                     11))))
        (setf (sap-ref-32 sap i) #xFD60FF))) ; JMP [RAX-3]
    ;; It is critical that there be a trailing 'uint16' of 0 in this object
    ;; so that CODE-N-ENTRIES reports 0.  By luck, there is exactly enough
    ;; room in the object to hold two 0 bytes. It would be easy enough to enlarge
    ;; by 2 words if it became necessary. The assertions makes sure we stay ok.
    (aver (zerop (code-n-entries code)))
    code))

;;; Return T if FUN can't be called without loading RAX with its descriptor.
;;; This is true of any funcallable instance which is not a GF, and closures.
(defun fun-requires-simplifying-trampoline-p (fun)
  (cond ((not (immobile-space-obj-p fun)) t) ; always
        (t
         (closurep fun))))

(defmacro !set-fin-trampoline (fin)
  `(let ((sap (int-sap (get-lisp-obj-address ,fin)))
         (insts-offs (- (ash (1+ funcallable-instance-info-offset) word-shift)
                        fun-pointer-lowtag)))
     (setf (sap-ref-word sap insts-offs) #xFFFFFFE9058B48 ; MOV RAX,[RIP-23]
           (sap-ref-32 sap (+ insts-offs 7)) #x00FD60FF))) ; JMP [RAX-3]

(defun %set-fdefn-fun (fdefn fun)
  (declare (type fdefn fdefn) (type function fun)
           (values function))
  (unless (eql (sb-vm::fdefn-has-static-callers fdefn) 0)
    (sb-vm::remove-static-links fdefn))
  (let ((trampoline (when (fun-requires-simplifying-trampoline-p fun)
                      (fun-immobilize fun)))) ; a newly made CODE object
    (with-pinned-objects (fdefn trampoline fun)
      (let* ((jmp-target
              (if trampoline
                  ;; Jump right to code-instructions + N. There's no simple-fun.
                  (sap-int (sap+ (code-instructions trampoline)
                                 trampoline-entry-offset))
                  ;; CLOSURE-CALLEE accesses the self pointer of a funcallable
                  ;; instance w/ builtin trampoline, or a simple-fun.
                  ;; But the result is shifted by N-FIXNUM-TAG-BITS because
                  ;; CELL-REF yields a descriptor-reg, not an unsigned-reg.
                  (get-lisp-obj-address (%closure-callee fun))))
             (tagged-ptr-bias
              ;; compute the difference between the entry address
              ;; and the tagged pointer to the called object.
              (the (unsigned-byte 8)
                   (- jmp-target (get-lisp-obj-address (or trampoline fun)))))
             (fdefn-addr (- (get-lisp-obj-address fdefn) ; base of the object
                            other-pointer-lowtag))
             (jmp-origin ; 5 = instruction length
              (+ fdefn-addr (ash fdefn-raw-addr-slot word-shift) 5))
             (jmp-operand
              (ldb (byte 32 0) (the (signed-byte 32) (- jmp-target jmp-origin))))
             (instruction
              (logior #xE9 ; JMP opcode
                      (ash jmp-operand 8)
                      (ash #xA890 40) ; "NOP ; TEST %AL, #xNN"
                      (ash tagged-ptr-bias 56))))
        (%primitive sb-vm::set-fdefn-fun fdefn fun instruction))))
  fun)

) ; end PROGN

;;; Find an immobile FDEFN or FUNCTION given an interior pointer to it.
#+immobile-space
(defun find-called-object (address)
  (let ((obj (alien-funcall (extern-alien "search_all_gc_spaces"
                                          (function unsigned unsigned))
                            address)))
    (unless (eql obj 0)
      (case (sap-ref-8 (int-sap obj) 0)
        (#.code-header-widetag
         (%simple-fun-from-entrypoint
          (make-lisp-obj (logior obj other-pointer-lowtag))
          address))
        (#.fdefn-widetag
         (make-lisp-obj (logior obj other-pointer-lowtag)))
        (#.funcallable-instance-widetag
         (make-lisp-obj (logior obj fun-pointer-lowtag)))))))

;;; Compute the PC that FDEFN will jump to when called.
#+immobile-code
(defun fdefn-call-target (fdefn)
  (let ((pc (+ (get-lisp-obj-address fdefn)
               (- other-pointer-lowtag)
               (ash fdefn-raw-addr-slot word-shift))))
    (+ pc 5 (signed-sap-ref-32 (int-sap pc) 1)))) ; 5 = length of JMP

;;; Undo the effects of XEP-ALLOCATE-FRAME
;;; and point PC to FUNCTION
(defun context-call-function (context function &optional arg-count)
  (with-pinned-objects (function)
    (let ((rsp (decf (context-register context rsp-offset) n-word-bytes))
          (rbp (context-register context rbp-offset))
          (fun-addr (get-lisp-obj-address function)))
      (setf (sap-ref-word (int-sap rsp) 0)
            (sap-ref-word (int-sap rbp) 8))
      (when arg-count
        (setf (context-register context rcx-offset)
              (get-lisp-obj-address arg-count)))
      (setf (context-register context rax-offset) fun-addr)
      (set-context-pc context (sap-ref-word (int-sap fun-addr)
                                            (- (ash simple-fun-self-slot word-shift)
                                               fun-pointer-lowtag))))))

;;; CALL-DIRECT-P when true indicates that at the instruction level
;;; it is fine to change the JMP or CALL instruction - i.e. the offset is
;;; a (SIGNED-BYTE 32), and the function can be called without loading
;;; its address into RAX, *and* there is a 1:1 relation between the fdefns
;;; and fdefn-funs for all callees of the code that contains FUN.
;;; The 1:1 constraint is due to a design limit - when removing static links,
;;; it is impossible to distinguish fdefns that point to the same called function.
;;; FIXME: It would be a nice to remove the uniqueness constraint, either
;;; by recording ay ambiguous fdefns, or just recording all replacements.
;;; Perhaps we could remove the static linker mutex as well?
(defun call-direct-p (fun code-header-funs)
  #-immobile-code (declare (ignore fun code-header-funs))
  #+immobile-code
  (flet ((singly-occurs-p (thing things &aux (len (length things)))
           ;; Return T if THING occurs exactly once in vector THINGS.
           (declare (simple-vector things))
           (dotimes (i len)
             (when (eq (svref things i) thing)
               ;; re-using I as the index is OK because we leave the outer loop
               ;; after this.
               (return (loop (cond ((>= (incf i) len) (return t))
                                   ((eq thing (svref things i)) (return nil)))))))))
    (and (immobile-space-obj-p fun)
         (not (fun-requires-simplifying-trampoline-p fun))
         (singly-occurs-p fun code-header-funs))))

;;; Allocate a code object.
(defun alloc-dynamic-space-code (total-words)
  (values (%primitive alloc-dynamic-space-code (the fixnum total-words))))

;;; Remove calls via fdefns from CODE when compiling into memory.
(defun statically-link-code-obj (code fixups)
  (declare (ignorable fixups))
  (unless (and (immobile-space-obj-p code)
               (fboundp 'sb-vm::remove-static-links))
    (return-from statically-link-code-obj))
  #+immobile-code
  (let ((insts (code-instructions code))
        (fdefns)) ; group by fdefn
    (loop for (offset . name) in fixups
          do (binding* ((fdefn (find-fdefn name) :exit-if-null)
                        (cell (assq fdefn fdefns)))
               (if cell
                   (push offset (cdr cell))
                   (push (list fdefn offset) fdefns))))
    (let ((funs (make-array (length fdefns))))
      (sb-thread::with-system-mutex (sb-c::*static-linker-lock*)
        (loop for i from 0 for (fdefn) in fdefns
              do (setf (aref funs i) (fdefn-fun fdefn)))
        (dolist (fdefn-use fdefns)
          (let* ((fdefn (car fdefn-use))
                 (callee (fdefn-fun fdefn)))
            ;; Because we're holding the static linker lock, the elements of
            ;; FUNS can not change while this test is performed.
            (when (call-direct-p callee funs)
              (let ((entry (sb-vm::fdefn-call-target fdefn)))
                (dolist (offset (cdr fdefn-use))
                  ;; Only a CALL or JMP will get statically linked.
                  ;; A MOV will always load the address of the fdefn.
                  (when (eql (logior (sap-ref-8 insts (1- offset)) 1) #xE9)
                    ;; Set the statically-linked flag
                    (setf (sb-vm::fdefn-has-static-callers fdefn) 1)
                    ;; Change the machine instruction
                    (setf (signed-sap-ref-32 insts offset)
                          (- entry (+ (sap-int (sap+ insts offset)) 4)))))))))))))
