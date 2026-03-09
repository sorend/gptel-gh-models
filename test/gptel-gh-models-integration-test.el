;;; gptel-gh-models-integration-test.el --- Live integration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; This file is part of gptel-gh-models.
;; It is NOT part of GNU Emacs.

;;; Commentary:

;; Live integration tests for gptel-gh-models.el.
;;
;; These tests make REAL HTTP requests to the GitHub Copilot API.
;; They require an authenticated Emacs installation (token files at
;; the paths configured in `gptel-gh-github-token-file' and
;; `gptel-gh-token-file').
;;
;; Running with make:
;;   make integration-test
;;
;; Running manually:
;;   emacs -Q --batch -L . -L /path/to/gptel \
;;     -l ert -l gptel-gh-models.el \
;;     -l test/gptel-gh-models-integration-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-gh-models)

;;; ------------------------------------------------------------------
;; Helpers
;; ------------------------------------------------------------------

(defun gptel-gh-models-itest--backend-name ()
  "Return a unique backend name for the integration test run."
  (format "GH-Copilot-Integration-Test-%d" (random 100000)))

;;; ------------------------------------------------------------------
;; Integration tests: live API fetch
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models-integration/setup-returns-backend ()
  "gptel-gh-models-setup returns a valid backend struct against the live API."
  (let* ((name    (gptel-gh-models-itest--backend-name))
         (backend (gptel-gh-models-setup :name name)))
    (should (gptel-backend-p backend))
    ;; Clean up
    (setq gptel--known-backends
          (assoc-delete-all name gptel--known-backends #'equal))))

(ert-deftest gptel-gh-models-integration/fetches-nonempty-model-list ()
  "The live API returns at least one chat model."
  (let* ((name    (gptel-gh-models-itest--backend-name))
         (backend (gptel-gh-models-setup :name name))
         (models  (gptel-backend-models backend)))
    (should (> (length models) 0))
    (message "gptel-gh-models integration: fetched %d models: %S"
             (length models) models)
    ;; Clean up
    (setq gptel--known-backends
          (assoc-delete-all name gptel--known-backends #'equal))))

(ert-deftest gptel-gh-models-integration/models-are-symbols ()
  "Every model entry in the backend is a symbol."
  (let* ((name    (gptel-gh-models-itest--backend-name))
         (backend (gptel-gh-models-setup :name name))
         (models  (gptel-backend-models backend)))
    (should (cl-every #'symbolp models))
    ;; Clean up
    (setq gptel--known-backends
          (assoc-delete-all name gptel--known-backends #'equal))))

(ert-deftest gptel-gh-models-integration/known-model-present ()
  "At least one well-known model (gpt-4o or claude-*) is in the list."
  (let* ((name    (gptel-gh-models-itest--backend-name))
         (backend (gptel-gh-models-setup :name name))
         (models  (gptel-backend-models backend)))
    (should (cl-some (lambda (id)
                       (or (eq id 'gpt-4o)
                           (string-prefix-p "claude-" (symbol-name id))))
                     models))
    ;; Clean up
    (setq gptel--known-backends
          (assoc-delete-all name gptel--known-backends #'equal))))

(ert-deftest gptel-gh-models-integration/vision-models-have-mime-types ()
  "Models fetched from the live API that support vision have mime-types set."
  (let* ((name    (gptel-gh-models-itest--backend-name))
         (backend (gptel-gh-models-setup :name name))
         (models  (gptel-backend-models backend))
         ;; gptel stores models as symbols; capabilities are on the symbol plist.
         (vision-models
          (cl-remove-if-not
           (lambda (m)
             (memq 'media (get m :capabilities)))
           models)))
    ;; There should be at least one vision-capable model
    (should (> (length vision-models) 0))
    ;; Each vision model must carry mime-types
    (dolist (m vision-models)
      (should (get m :mime-types)))
    (message "gptel-gh-models integration: %d vision-capable models: %S"
             (length vision-models) vision-models)
    ;; Clean up
    (setq gptel--known-backends
          (assoc-delete-all name gptel--known-backends #'equal))))

(provide 'gptel-gh-models-integration-test)
;;; gptel-gh-models-integration-test.el ends here
