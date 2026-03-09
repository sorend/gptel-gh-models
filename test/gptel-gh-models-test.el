;;; gptel-gh-models-test.el --- ERT tests for gptel-gh-models -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Soren A D

;; SPDX-License-Identifier: MIT

;; This file is part of gptel-gh-models.
;; It is NOT part of GNU Emacs.

;;; Commentary:

;; ERT test suite for gptel-gh-models.el.
;;
;; These tests cover:
;;   - Capability and MIME-type mapping from the API response format
;;   - Context-window parsing
;;   - Single model object parsing (gptel-gh-models--parse-model)
;;   - Full API response parsing (gptel-gh-models--parse-response)
;;   - Filtering of non-chat models (embeddings etc.)
;;
;; Tests that require live network access are NOT included; the suite
;; is designed to run fully offline in a headless Emacs process.
;;
;; Running with make:
;;   make test
;;
;; Running manually:
;;   emacs -Q --batch -L . -L /path/to/gptel \
;;     -l ert -l gptel-gh-models.el \
;;     -l test/gptel-gh-models-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; ------------------------------------------------------------------
;; gptel is always on the load-path when running via `make test'.
;; The real packages are loaded transitively by gptel-gh-models below.
;; ------------------------------------------------------------------

(require 'gptel-gh-models)

;;; ------------------------------------------------------------------
;; Test fixtures
;; ------------------------------------------------------------------

(defconst gptel-gh-models-test--full-model
  '(:id "gpt-4o"
    :name "GPT 4o"
    :object "model"
    :vendor "Azure OpenAI"
    :version "gpt-4o-2024-11-20"
    :preview :json-false
    :model_picker_enabled t
    :capabilities
    (:object "model_capabilities"
     :type "chat"
     :family "gpt-4o"
     :tokenizer "o200k_base"
     :supports
     (:streaming t
      :tool_calls t
      :parallel_tool_calls t)
     :limits
     (:max_context_window_tokens 128000
      :max_output_tokens 16384
      :max_prompt_tokens 111616
      :vision (:max_prompt_image_size 3145728
               :max_prompt_images 1
               :supported_media_types ["image/jpeg" "image/png" "image/webp" "image/gif"]))))
  "Sample chat model plist matching the current GitHub Copilot API shape.
Vision support is indicated by a limits.vision object, not supports.vision.")

(defconst gptel-gh-models-test--text-model
  '(:id "gpt-4o-mini"
    :name "GPT 4o Mini"
    :object "model"
    :capabilities
    (:type "chat"
     :supports
     (:streaming t
      :tool_calls t)
     :limits
     (:max_context_window_tokens 64000)))
  "Sample chat model without vision support (no limits.vision object).")

(defconst gptel-gh-models-test--embedding-model
  '(:id "text-embedding-3-small"
    :name "Text Embedding 3 Small"
    :object "model"
    :capabilities
    (:type "embeddings"
     :supports ()))
  "Sample embeddings model that should be filtered out.")

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--truthy-p
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--truthy-p/t ()
  "t is truthy."
  (should (gptel-gh-models--truthy-p t)))

(ert-deftest gptel-gh-models--truthy-p/string ()
  "A non-empty string is truthy."
  (should (gptel-gh-models--truthy-p "yes")))

(ert-deftest gptel-gh-models--truthy-p/nil ()
  "nil is falsy."
  (should-not (gptel-gh-models--truthy-p nil)))

(ert-deftest gptel-gh-models--truthy-p/json-false ()
  ":json-false (Emacs JSON library false) is falsy."
  (should-not (gptel-gh-models--truthy-p :json-false)))

(ert-deftest gptel-gh-models--truthy-p/false-keyword ()
  ":false is treated as falsy."
  (should-not (gptel-gh-models--truthy-p :false)))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--map-capabilities
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--map-capabilities/tool-use-only ()
  "tool_calls=t => tool-use capability; no media when vision is nil."
  (let ((caps (gptel-gh-models--map-capabilities
               '(:tool_calls t) nil)))
    (should     (memq 'tool-use caps))
    (should-not (memq 'media    caps))
    (should     (memq 'json     caps))))

(ert-deftest gptel-gh-models--map-capabilities/vision-only ()
  "Non-nil vision object => media capability; no tool-use."
  (let ((caps (gptel-gh-models--map-capabilities
               '(:tool_calls :json-false)
               '(:max_prompt_images 1))))
    (should     (memq 'media    caps))
    (should-not (memq 'tool-use caps))))

(ert-deftest gptel-gh-models--map-capabilities/both ()
  "tool_calls and vision produce tool-use and media."
  (let ((caps (gptel-gh-models--map-capabilities
               '(:tool_calls t)
               '(:max_prompt_images 1))))
    (should (memq 'tool-use caps))
    (should (memq 'media    caps))
    (should (memq 'json     caps))
    (should (memq 'url      caps))))

(ert-deftest gptel-gh-models--map-capabilities/neither ()
  "No tool_calls and nil vision still yield json and url."
  (let ((caps (gptel-gh-models--map-capabilities '() nil)))
    (should     (memq 'json caps))
    (should     (memq 'url  caps))
    (should-not (memq 'tool-use caps))
    (should-not (memq 'media    caps))))

(ert-deftest gptel-gh-models--map-capabilities/nil-supports ()
  "Nil supports plist with nil vision is handled gracefully."
  (let ((caps (gptel-gh-models--map-capabilities nil nil)))
    (should (listp caps))
    (should (memq 'json caps))))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--map-mime-types
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--map-mime-types/with-vision ()
  "A vision object with supported_media_types returns those types."
  (let ((mimes (gptel-gh-models--map-mime-types
                '(:max_prompt_images 1
                  :supported_media_types ["image/jpeg" "image/png"
                                          "image/gif" "image/webp"]))))
    (should (member "image/jpeg" mimes))
    (should (member "image/png"  mimes))
    (should (member "image/gif"  mimes))
    (should (member "image/webp" mimes))))

(ert-deftest gptel-gh-models--map-mime-types/vision-no-media-types ()
  "A vision object without supported_media_types falls back to defaults."
  (let ((mimes (gptel-gh-models--map-mime-types '(:max_prompt_images 1))))
    (should (member "image/jpeg" mimes))
    (should (member "image/png"  mimes))))

(ert-deftest gptel-gh-models--map-mime-types/no-vision ()
  "Nil vision yields no MIME types."
  (should-not (gptel-gh-models--map-mime-types nil)))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--context-window-k
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--context-window-k/128k ()
  "128000 tokens => 128 (thousands)."
  (should (= 128 (gptel-gh-models--context-window-k
                  '(:max_context_window_tokens 128000)))))

(ert-deftest gptel-gh-models--context-window-k/64k ()
  "64000 tokens => 64."
  (should (= 64 (gptel-gh-models--context-window-k
                 '(:max_context_window_tokens 64000)))))

(ert-deftest gptel-gh-models--context-window-k/nil-limits ()
  "nil limits plist returns nil."
  (should-not (gptel-gh-models--context-window-k nil)))

(ert-deftest gptel-gh-models--context-window-k/zero ()
  "Zero tokens returns nil (not a useful context window)."
  (should-not (gptel-gh-models--context-window-k
               '(:max_context_window_tokens 0))))

(ert-deftest gptel-gh-models--context-window-k/missing-key ()
  "Missing key in limits returns nil."
  (should-not (gptel-gh-models--context-window-k
               '(:max_output_tokens 4096))))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--parse-model
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--parse-model/returns-cons ()
  "parse-model returns a cons cell for a valid chat model."
  (let ((spec (gptel-gh-models--parse-model gptel-gh-models-test--full-model)))
    (should (consp spec))))

(ert-deftest gptel-gh-models--parse-model/symbol-from-id ()
  "The car of the result is a symbol interned from the model id."
  (let ((spec (gptel-gh-models--parse-model gptel-gh-models-test--full-model)))
    (should (eq 'gpt-4o (car spec)))))

(ert-deftest gptel-gh-models--parse-model/description-from-name ()
  "The :description in the plist matches the API name field."
  (let* ((spec  (gptel-gh-models--parse-model gptel-gh-models-test--full-model))
         (props (cdr spec)))
    (should (equal "GPT 4o" (plist-get props :description)))))

(ert-deftest gptel-gh-models--parse-model/context-window ()
  "Context window is derived from max_context_window_tokens / 1000."
  (let* ((spec  (gptel-gh-models--parse-model gptel-gh-models-test--full-model))
         (props (cdr spec)))
    (should (= 128 (plist-get props :context-window)))))

(ert-deftest gptel-gh-models--parse-model/capabilities ()
  "Capabilities list contains tool-use and media for a full model."
  (let* ((spec  (gptel-gh-models--parse-model gptel-gh-models-test--full-model))
         (caps  (plist-get (cdr spec) :capabilities)))
    (should (memq 'tool-use caps))
    (should (memq 'media    caps))
    (should (memq 'json     caps))))

(ert-deftest gptel-gh-models--parse-model/mime-types ()
  "MIME types are included for a model with vision support."
  (let* ((spec  (gptel-gh-models--parse-model gptel-gh-models-test--full-model))
         (mimes (plist-get (cdr spec) :mime-types)))
    (should (member "image/jpeg" mimes))
    (should (member "image/png"  mimes))))

(ert-deftest gptel-gh-models--parse-model/no-vision-no-mimes ()
  "A model without vision has no :mime-types key in its plist."
  (let* ((spec  (gptel-gh-models--parse-model gptel-gh-models-test--text-model))
         (props (cdr spec)))
    (should-not (plist-get props :mime-types))))

(ert-deftest gptel-gh-models--parse-model/embedding-returns-nil ()
  "Embedding models return nil (not chat type)."
  (should-not (gptel-gh-models--parse-model
               gptel-gh-models-test--embedding-model)))

(ert-deftest gptel-gh-models--parse-model/no-id-returns-nil ()
  "A model with no :id returns nil."
  (should-not (gptel-gh-models--parse-model
               '(:name "Nameless" :capabilities (:type "chat" :supports ())))))

(ert-deftest gptel-gh-models--parse-model/no-capabilities-returns-nil ()
  "A model with no capabilities (no :type) returns nil."
  (should-not (gptel-gh-models--parse-model
               '(:id "mystery" :name "Mystery"))))

(ert-deftest gptel-gh-models--parse-model/zero-cost ()
  "GitHub Copilot models have zero cost values (included in subscription)."
  (let* ((spec  (gptel-gh-models--parse-model gptel-gh-models-test--full-model))
         (props (cdr spec)))
    (should (= 0 (plist-get props :input-cost)))
    (should (= 0 (plist-get props :output-cost)))))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--parse-response
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--parse-response/single-model ()
  "A response with one chat model returns one spec."
  (let* ((response `(:object "list"
                     :data ,(vector gptel-gh-models-test--full-model)))
         (specs (gptel-gh-models--parse-response response)))
    (should (= 1 (length specs)))
    (should (eq 'gpt-4o (caar specs)))))

(ert-deftest gptel-gh-models--parse-response/multiple-models ()
  "Multiple chat models are all returned."
  (let* ((response `(:object "list"
                     :data ,(vector gptel-gh-models-test--full-model
                                    gptel-gh-models-test--text-model)))
         (specs (gptel-gh-models--parse-response response)))
    (should (= 2 (length specs)))))

(ert-deftest gptel-gh-models--parse-response/filters-embeddings ()
  "Embedding models are excluded from the result."
  (let* ((response `(:object "list"
                     :data ,(vector gptel-gh-models-test--full-model
                                    gptel-gh-models-test--embedding-model)))
         (specs (gptel-gh-models--parse-response response)))
    (should (= 1 (length specs)))
    (should (eq 'gpt-4o (caar specs)))))

(ert-deftest gptel-gh-models--parse-response/all-embeddings-returns-nil ()
  "When only embeddings are present, return nil."
  (let* ((response `(:object "list"
                     :data ,(vector gptel-gh-models-test--embedding-model)))
         (specs (gptel-gh-models--parse-response response)))
    (should-not specs)))

(ert-deftest gptel-gh-models--parse-response/empty-data ()
  "An empty data array returns nil."
  (should-not (gptel-gh-models--parse-response '(:object "list" :data []))))

(ert-deftest gptel-gh-models--parse-response/no-data-key ()
  "A response with no :data key returns nil."
  (should-not (gptel-gh-models--parse-response '(:object "list"))))

(ert-deftest gptel-gh-models--parse-response/data-as-list ()
  "The :data value may be a list instead of a vector."
  (let* ((response `(:object "list"
                     :data ,(list gptel-gh-models-test--full-model)))
         (specs (gptel-gh-models--parse-response response)))
    (should (= 1 (length specs)))))

(ert-deftest gptel-gh-models--parse-response/model-symbols ()
  "Each returned spec has a symbol as its car."
  (let* ((response `(:object "list"
                     :data ,(vector gptel-gh-models-test--full-model
                                    gptel-gh-models-test--text-model)))
         (specs (gptel-gh-models--parse-response response)))
    (should (cl-every #'symbolp (mapcar #'car specs)))))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--get-session-token (with stubs)
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--get-session-token/auth-error-returns-nil ()
  "When gptel--gh-auth signals an error, nil is returned."
  (let* ((backend (gptel-make-gh-copilot "test-backend-auth-err")))
    (cl-letf (((symbol-function 'gptel--gh-auth)
               (lambda () (error "Simulated auth failure"))))
      (should-not (gptel-gh-models--get-session-token backend)))))

(ert-deftest gptel-gh-models--get-session-token/returns-token-string ()
  "When auth succeeds, the bearer token string is returned.

`gptel--gh-auth' is stubbed to be a no-op.  The token slot is
pre-seeded with a fake plist so the inlined slot accessor reads
back the correct value without hitting the network."
  (let* ((backend    (gptel-make-gh-copilot "test-backend-auth-ok"))
         (fake-token "ghu_test_token_12345"))
    (setf (gptel--gh-token backend)
          (list :token fake-token :expires_at 9999999999))
    (cl-letf (((symbol-function 'gptel--gh-auth) #'ignore))
      (should (equal fake-token
                     (gptel-gh-models--get-session-token backend))))))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models--fetch-with-token (with stubs)
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models--fetch-with-token/successful-fetch ()
  "A successful API response is parsed into model specs."
  (let ((fake-response `(:object "list"
                         :data ,(vector gptel-gh-models-test--full-model))))
    (cl-letf (((symbol-function 'gptel--url-retrieve)
               (lambda (_url &rest _args) fake-response)))
      (let ((specs (gptel-gh-models--fetch-with-token "test-token")))
        (should (= 1 (length specs)))
        (should (eq 'gpt-4o (caar specs)))))))

(ert-deftest gptel-gh-models--fetch-with-token/network-error-returns-nil ()
  "A network error during fetch returns nil without signaling."
  (cl-letf (((symbol-function 'gptel--url-retrieve)
             (lambda (_url &rest _args) (error "Connection refused"))))
    (should-not (gptel-gh-models--fetch-with-token "test-token"))))

(ert-deftest gptel-gh-models--fetch-with-token/empty-response-returns-nil ()
  "An API response with no models returns nil."
  (cl-letf (((symbol-function 'gptel--url-retrieve)
             (lambda (_url &rest _args) '(:object "list" :data []))))
    (should-not (gptel-gh-models--fetch-with-token "test-token"))))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models-setup (integration, with stubs)
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models-setup/creates-backend ()
  "setup creates and returns a backend struct.
Uses a stub for gptel-gh-models--get-session-token to isolate from auth."
  (let ((gptel--known-backends nil))
    (cl-letf (((symbol-function 'gptel-gh-models--get-session-token)
               (lambda (_b) "fake-tok"))
              ((symbol-function 'gptel--url-retrieve)
               (lambda (_url &rest _args)
                 `(:object "list"
                   :data ,(vector gptel-gh-models-test--full-model)))))
      (let ((backend (gptel-gh-models-setup :name "Test Copilot")))
        (should backend)
        (should (gptel-backend-p backend))))))

(ert-deftest gptel-gh-models-setup/registers-backend ()
  "setup registers the backend under its name in gptel--known-backends."
  (let ((gptel--known-backends nil))
    (cl-letf (((symbol-function 'gptel-gh-models--get-session-token)
               (lambda (_b) "fake-tok"))
              ((symbol-function 'gptel--url-retrieve)
               (lambda (_url &rest _args)
                 `(:object "list"
                   :data ,(vector gptel-gh-models-test--full-model)))))
      (gptel-gh-models-setup :name "My Copilot")
      (should (alist-get "My Copilot" gptel--known-backends nil nil #'equal)))))

(ert-deftest gptel-gh-models-setup/updates-models ()
  "After a successful setup, the backend's model list is updated.
Stubs gptel-gh-models--get-session-token (our own function) to avoid
depending on struct slot accessor stubbing which can be unreliable with
byte-compiled cl-defstruct accessors."
  (let ((gptel--known-backends nil))
    (cl-letf (((symbol-function 'gptel-gh-models--get-session-token)
               (lambda (_b) "fake-tok"))
              ((symbol-function 'gptel--url-retrieve)
               (lambda (_url &rest _args)
                 `(:object "list"
                   :data ,(vector gptel-gh-models-test--full-model
                                  gptel-gh-models-test--text-model)))))
      (let* ((backend (gptel-gh-models-setup :name "MC"))
             (models  (gptel-backend-models backend)))
        (should (= 2 (length models)))))))

(ert-deftest gptel-gh-models-setup/set-default ()
  "When :set-default t, gptel-backend and gptel-model are updated."
  (let ((gptel--known-backends nil)
        (gptel-backend nil)
        (gptel-model nil))
    (cl-letf (((symbol-function 'gptel-gh-models--get-session-token)
               (lambda (_b) "fake-tok"))
              ((symbol-function 'gptel--url-retrieve)
               (lambda (_url &rest _args)
                 `(:object "list"
                   :data ,(vector gptel-gh-models-test--full-model)))))
      (gptel-gh-models-setup :name "Default Copilot" :set-default t)
      (should gptel-backend)
      (should gptel-model))))

(ert-deftest gptel-gh-models-setup/auth-failure-still-returns-backend ()
  "Even when auth fails, a backend (with default models) is returned."
  (let ((gptel--known-backends nil))
    (cl-letf (((symbol-function 'gptel--gh-auth)
               (lambda () (error "No credentials"))))
      (let ((backend (gptel-gh-models-setup :name "Failsafe Copilot")))
        (should backend)
        (should (gptel-backend-p backend))))))

(ert-deftest gptel-gh-models-setup/reuses-existing-backend ()
  "Calling setup twice reuses the existing backend, not a new one."
  (let ((gptel--known-backends nil))
    (cl-letf (((symbol-function 'gptel-gh-models--get-session-token)
               (lambda (_b) "fake-tok"))
              ((symbol-function 'gptel--url-retrieve)
               (lambda (_url &rest _args)
                 `(:object "list"
                   :data ,(vector gptel-gh-models-test--full-model)))))
      (let ((b1 (gptel-gh-models-setup :name "Reuse Test"))
            (b2 (gptel-gh-models-setup :name "Reuse Test")))
        (should (eq b1 b2))))))

;;; ------------------------------------------------------------------
;; Tests: gptel-gh-models-update
;; ------------------------------------------------------------------

(ert-deftest gptel-gh-models-update/errors-without-backend ()
  "update signals a user-error when no backend exists."
  (let ((gptel--known-backends nil))
    (should-error (gptel-gh-models-update) :type 'user-error)))

(ert-deftest gptel-gh-models-update/calls-setup-when-backend-exists ()
  "update invokes setup when the backend is registered."
  (let ((gptel--known-backends nil)
        (called nil))
    (cl-letf (((symbol-function 'gptel-gh-models--get-session-token)
               (lambda (_b) "fake-tok"))
              ((symbol-function 'gptel--url-retrieve)
               (lambda (_url &rest _args)
                 `(:object "list"
                   :data ,(vector gptel-gh-models-test--full-model)))))
      ;; Create the backend first
      (gptel-gh-models-setup)
      ;; Now stub gptel-gh-models-setup to track the call
      (cl-letf (((symbol-function 'gptel-gh-models-setup)
                 (lambda (&rest _args) (setq called t))))
        (gptel-gh-models-update)
        (should called)))))

(provide 'gptel-gh-models-test)
;;; gptel-gh-models-test.el ends here
