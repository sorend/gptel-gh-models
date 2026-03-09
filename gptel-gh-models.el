;;; gptel-gh-models.el --- Dynamic model discovery for GitHub Copilot -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Soren A D

;; Author: Soren A D <soren@hamisoke.com>
;; Maintainer: Soren A D <soren@hamisoke.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (gptel "0.9.8"))
;; Keywords: convenience, tools, ai
;; URL: https://github.com/sorend/gptel-gh-models

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package extends gptel's GitHub Copilot support (gptel-gh) by
;; dynamically fetching the list of available models from the GitHub
;; Copilot API instead of relying on the hardcoded list in gptel-gh.
;;
;; It queries https://api.githubcopilot.com/models and registers a
;; gptel backend with the live set of models available on your account.
;;
;; Usage:
;;
;;   (require 'gptel-gh-models)
;;
;;   ;; Create the backend and fetch models (prompts for GitHub auth
;;   ;; the first time if no credentials are cached):
;;   (gptel-gh-models-setup)
;;
;;   ;; Optionally make it the default backend:
;;   (gptel-gh-models-setup :set-default t)
;;
;;   ;; Refresh models later without re-authenticating:
;;   (gptel-gh-models-update)
;;
;; The package reuses gptel-gh's OAuth device-flow authentication, so
;; credentials are shared with any other gptel-gh backend you may have.
;;
;; Model capabilities are discovered from the API response and mapped as
;; follows:
;;
;;   API field                        gptel capability
;;   ---------------------------------------------------------------
;;   supports.tool_calls = true       tool-use
;;   limits.vision present            media + image MIME types
;;   (always, OpenAI-compatible)      json, url

;;; Code:

(require 'cl-lib)
(require 'map)
(eval-and-compile
  (require 'gptel-request)
  (require 'gptel-gh))

;;; Customization

(defgroup gptel-gh-models nil
  "Fetch models dynamically from the GitHub Copilot API for gptel."
  :group 'gptel
  :prefix "gptel-gh-models-")

(defcustom gptel-gh-models-backend-name "GitHub Copilot"
  "Name for the GitHub Copilot gptel backend registered by this package."
  :type 'string
  :group 'gptel-gh-models)

(defcustom gptel-gh-models-api-url "https://api.githubcopilot.com/models"
  "URL of the GitHub Copilot models listing endpoint."
  :type 'string
  :group 'gptel-gh-models)

;;; Internal helpers

(defun gptel-gh-models--truthy-p (val)
  "Return non-nil if VAL represents a truthy JSON boolean.
Handles Emacs JSON false values (:json-false and :false) as falsy."
  (and val
       (not (eq val :json-false))
       (not (eq val :false))))

(defun gptel-gh-models--map-capabilities (supports vision)
  "Map GitHub Copilot API SUPPORTS plist and VISION object to gptel capabilities.

SUPPORTS is a plist from capabilities.supports, e.g.:
  \\='(:streaming t :tool_calls t :parallel_tool_calls t)

VISION is the plist from capabilities.limits.vision, or nil.
It is non-nil for models that declare vision support, e.g.:
  \\='(:max_prompt_images 1 :supported_media_types [\"image/jpeg\" ...])

Returns a list of capability symbols recognized by gptel, e.g.
  (tool-use media json url)"
  (let (caps)
    (when (gptel-gh-models--truthy-p (plist-get supports :tool_calls))
      (push 'tool-use caps))
    (when vision
      (push 'media caps))
    ;; OpenAI-compatible endpoints support JSON structured output and URL context
    (push 'json caps)
    (push 'url caps)
    caps))

(defun gptel-gh-models--map-mime-types (vision)
  "Return a list of MIME types the model accepts based on VISION object.

VISION is the plist from capabilities.limits.vision, or nil, or t.
When it is a plist it may contain :supported_media_types; those are
returned directly.  When it is just t (old boolean API format) or a
plist without that key, a common fallback set is returned.

Returns nil when VISION is nil (vision not supported)."
  (when vision
    (let ((types (when (listp vision)
                   (plist-get vision :supported_media_types))))
      (cond
       ((vectorp types) (append types nil))
       ((consp types)   types)
       (t               '("image/jpeg" "image/png" "image/webp"))))))

(defun gptel-gh-models--context-window-k (limits)
  "Return the context window size in thousands of tokens from LIMITS.

LIMITS is a plist like \\='(:max_context_window_tokens 128000 ...).
Returns nil when LIMITS is nil or the token count is zero."
  (when-let* ((tokens (and limits (plist-get limits :max_context_window_tokens)))
              ((numberp tokens))
              ((> tokens 0)))
    (/ tokens 1000)))

(defun gptel-gh-models--parse-model (model-obj)
  "Parse a single MODEL-OBJ plist from the API into a gptel model spec.

MODEL-OBJ is a plist representing one entry from the API \\='data\\=' array.

Returns a cons cell (SYMBOL . PLIST) compatible with `gptel--process-models',
or nil if the model is not a chat model or has no id."
  (let* ((id           (plist-get model-obj :id))
         (name         (plist-get model-obj :name))
         (capabilities (plist-get model-obj :capabilities))
         (cap-type     (plist-get capabilities :type))
         (supports     (plist-get capabilities :supports))
         (limits       (plist-get capabilities :limits))
         ;; Vision support is signalled by a limits.vision object (new API shape).
         ;; Older API responses may use a supports.vision boolean instead.
         (vision       (or (and limits (plist-get limits :vision))
                           (and (gptel-gh-models--truthy-p
                                 (plist-get supports :vision))
                                t))))
    ;; Only include chat models; skip embeddings, completions, etc.
    (when (and id (equal cap-type "chat"))
      (let* ((model-sym      (intern id))
             (caps           (gptel-gh-models--map-capabilities supports vision))
             (mimes          (gptel-gh-models--map-mime-types vision))
             (context-window (gptel-gh-models--context-window-k limits))
             (props          (list :description (or name id)
                                   :capabilities caps
                                   :input-cost 0
                                   :output-cost 0)))
        (when context-window
          (setq props (append props (list :context-window context-window))))
        (when mimes
          (setq props (append props (list :mime-types mimes))))
        (cons model-sym props)))))

(defun gptel-gh-models--parse-response (response)
  "Parse a models API RESPONSE plist into a list of gptel model specs.

RESPONSE is the plist returned by `gptel--url-retrieve' for the
models endpoint.  The \\='data\\=' key holds a vector (or list) of
model objects.

Returns a list of (SYMBOL . PLIST) cons cells, filtering out
non-chat models and any entries that fail to parse."
  (when-let* ((data (plist-get response :data)))
    (delq nil
          (mapcar #'gptel-gh-models--parse-model
                  ;; JSON arrays arrive as vectors; coerce to list
                  (if (vectorp data) (append data nil) data)))))

(defun gptel-gh-models--fetch-with-token (token)
  "Fetch models from the GitHub Copilot API using bearer TOKEN.

Makes a synchronous GET request to `gptel-gh-models-api-url'.
Returns a list of (SYMBOL . PLIST) model specs on success, or nil
if the request fails or the response contains no chat models."
  (condition-case err
      (let* ((response
              (gptel--url-retrieve
               gptel-gh-models-api-url
               :headers
               `(("authorization"
                  . ,(concat "Bearer " token))
                 ;; The models endpoint requires a whitelisted IDE name;
                 ;; "emacs/<version>" is not accepted.
                 ("editor-version"
                  . "vscode/1.99.0")
                 ("editor-plugin-version"
                  . "gptel-gh-models/0.1")))))
        (gptel-gh-models--parse-response response))
    (error
     (message "gptel-gh-models: Error fetching models: %s"
              (error-message-string err))
     nil)))

(defun gptel-gh-models--get-session-token (backend)
  "Authenticate BACKEND and return the session token string.

Calls `gptel--gh-auth' with `gptel-backend' bound to BACKEND so
that all auth mutations target the correct backend struct.

Returns the bearer token string on success, or nil if
authentication fails (with a message describing the error)."
  (condition-case err
      (let ((gptel-backend backend))
        (gptel--gh-auth)
        (plist-get (gptel--gh-token backend) :token))
    (error
     (message "gptel-gh-models: Authentication failed: %s"
              (error-message-string err))
     nil)))

;;; Public API

;;;###autoload
(cl-defun gptel-gh-models-setup (&key (name gptel-gh-models-backend-name)
                                      set-default)
  "Set up a GitHub Copilot backend with models fetched from the API.

NAME is the backend name (defaults to `gptel-gh-models-backend-name').

When SET-DEFAULT is non-nil, the created backend is set as the
active `gptel-backend' and its first model as `gptel-model'.

The function creates or reuses a backend named NAME, authenticates
(prompting via the OAuth device flow the first time), then fetches
the current model list from the GitHub Copilot API and updates the
backend.  If fetching fails, the backend retains the default model
list from `gptel--gh-models'.

Returns the configured backend struct."
  (interactive)
  (let* ((existing (alist-get name gptel--known-backends nil nil #'equal))
         ;; Create backend first so auth can use its credential slots
         (backend  (or existing (gptel-make-gh-copilot name)))
         (token    (gptel-gh-models--get-session-token backend)))
    (if token
        (let ((models (gptel-gh-models--fetch-with-token token)))
          (if models
              (progn
                (setf (gptel-backend-models backend)
                      (gptel--process-models models))
                (message "gptel-gh-models: Loaded %d models for \"%s\""
                         (length models) name))
            (message "gptel-gh-models: No models returned from API; \
using defaults for \"%s\""
                     name)))
      (message "gptel-gh-models: Auth unavailable; \
using default models for \"%s\""
               name))
    (when set-default
      (setq gptel-backend backend
            gptel-model   (car (gptel-backend-models backend))))
    backend))

;;;###autoload
(defun gptel-gh-models-update ()
  "Refresh the model list for the GitHub Copilot backend from the API.

The backend named `gptel-gh-models-backend-name' must already exist
(i.e. `gptel-gh-models-setup' must have been called at least once).

Signals a user error if no such backend is found."
  (interactive)
  (if (alist-get gptel-gh-models-backend-name
                 gptel--known-backends nil nil #'equal)
      (gptel-gh-models-setup :name gptel-gh-models-backend-name)
    (user-error
     "No backend \"%s\" found.  Run `gptel-gh-models-setup' first"
     gptel-gh-models-backend-name)))

(provide 'gptel-gh-models)
;;; gptel-gh-models.el ends here
