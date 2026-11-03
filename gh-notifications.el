;;; gh-notifications.el --- GitHub notification manager  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Jack Baldry

;; Author: Jack Baldry
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "3.3.0") (transient "0.7.0") (ghub "3.6.0"))
;; Keywords: tools, convenience, github
;; Homepage: https://github.com/jdbaldry/gh-notifications.el

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

;; gh-notifications.el is a GitHub notification manager for Emacs.
;; It provides a magit-section based list buffer with transient dispatch,
;; batch operations, filtering, and background polling.

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'magit-section)
(require 'transient)
(require 'ghub)

;;; Customization

(defgroup gh-notifications nil
  "GitHub notification manager."
  :group 'tools
  :link '(url-link "https://github.com/jdbaldry/gh-notifications.el"))

(defcustom gh-notifications-host "api.github.com"
  "GitHub API host."
  :type 'string
  :group 'gh-notifications)

(defcustom gh-notifications-fetch-all nil
  "When non-nil, fetch all notifications including already-read ones.
When nil (the default), fetch only unread notifications."
  :type 'boolean
  :group 'gh-notifications)

(defcustom gh-notifications-max-pages 10
  "Maximum number of pages to fetch in a single refresh.
Each page contains 50 notifications.  Increase this if you have
more than 500 unread notifications."
  :type 'natnum
  :group 'gh-notifications)

(defcustom gh-notifications-my-prs-query "is:pr is:open sort:updated-desc"
  "GitHub search query used for the My PRs view.
When it contains `%s', the current login is interpolated there.
Otherwise `author:<login>' is appended automatically."
  :type 'string
  :group 'gh-notifications)

(defcustom gh-notifications-my-prs-max-pages 10
  "Maximum number of Search API pages to fetch for the My PRs view.
Each page contains up to 100 pull requests."
  :type 'natnum
  :group 'gh-notifications)

(defcustom gh-notifications-poll-interval 60
  "Number of seconds between background notification polls.
Set to nil to disable automatic polling."
  :type '(choice (const :tag "Disabled" nil)
                 (natnum :tag "Seconds"))
  :group 'gh-notifications)

(defcustom gh-notifications-auto-mark-done-days nil
  "Automatically mark notifications done after this many days.
Set to nil to disable automatic cleanup."
  :type '(choice (const :tag "Disabled" nil)
                 (natnum :tag "Days"))
  :group 'gh-notifications)

(defcustom gh-notifications-prune-missing-after-fetch t
  "When non-nil, remove local inbox notifications missing from a full remote fetch.
Notifications in `gh-notifications--kept-ids' are never pruned.
Pruning is skipped when pagination truncates at `gh-notifications-max-pages'."
  :type 'boolean
  :group 'gh-notifications)

(defcustom gh-notifications-older-than-days 7
  "Notifications older than this many days are dimmed in the buffer."
  :type 'natnum
  :group 'gh-notifications)

(defcustom gh-notifications-pinned-users
  '("robbymilo" "nate-walters-grafana" "marc-nogue")
  "GitHub login names shown as quick-filter shortcuts in the dispatch menu.
Each user can be toggled on and off with a single key from the Users section
of `gh-notifications-dispatch'."
  :type '(repeat string)
  :group 'gh-notifications)

(defcustom gh-notifications-renovate-logins
  '("renovate[bot]" "renovate-sh-app[bot]" "renovate-bot")
  "GitHub login names treated as Renovate when hiding Renovate pull requests.
The hosted Renovate app authors pull requests as \"renovate[bot]\".
The Mend self-hosted GitHub app authors as \"renovate-sh-app[bot]\".
Other self-hosted deployments commonly use \"renovate-bot\"."
  :type '(repeat string)
  :group 'gh-notifications)

(defcustom gh-notifications-sweep-rules
  '(("deployment-tools cicd"
     :repo "/deployment_tools"
     :prefixes ("[CI/CD] Update"))
    ("website automation"
     :repo "/website"
     :prefixes ("[Sync technical documentation]"
                "[publish_dashboards]"
                "[news-update]"
                "[sitemap-update]"
                "[meetups-update]"
                "[rss-update]"
                "[plugins]"
                "Update Webinar"
                "Update Banner"
                "Update interactive learning content")))
  "Named rules for filtering and sweeping automated PRs.
Each entry is (NAME :repo REPO-SUFFIX :prefixes (PREFIX...)).
A notification matches a rule when its repository full name ends with
REPO-SUFFIX and its subject title starts with one of PREFIX
(case-insensitive).  `gh-notifications-sweep-inactive-rule' marks such PRs
done once they are merged or closed."
  :type '(alist :key-type string
                :value-type (plist :options ((:repo string)
                                             (:prefixes (repeat string)))))
  :group 'gh-notifications)

(defcustom gh-notifications-saved-file
  (locate-user-emacs-file "gh-notifications/saved.el")
  "File where saved-for-later notifications are persisted.
Read on first access and rewritten after every save or unsave."
  :type 'file
  :group 'gh-notifications)

(defcustom gh-notifications-augment-concurrency 5
  "Maximum number of simultaneous REST requests used to augment notifications.
Augmentation fetches PR and issue details (author, assignees, reviewers)
needed for user-based filtering."
  :type 'natnum
  :group 'gh-notifications)

;;; Faces

(defface gh-notifications-unread
  '((t :inherit (magit-section-heading) :weight bold))
  "Face for unread notification titles."
  :group 'gh-notifications)

(defface gh-notifications-read
  '((t :inherit magit-dimmed))
  "Face for read notification titles."
  :group 'gh-notifications)

(defface gh-notifications-old
  '((t :inherit magit-dimmed :slant italic))
  "Face for notifications older than `gh-notifications-older-than-days'."
  :group 'gh-notifications)

(defface gh-notifications-repo
  '((t :inherit magit-section-heading))
  "Face for repository section headings."
  :group 'gh-notifications)

(defface gh-notifications-count
  '((t :inherit magit-section-child-count))
  "Face for the notification count badge on repository headings."
  :group 'gh-notifications)

(defface gh-notifications-type-pr
  '((t :inherit magit-branch-remote))
  "Face for pull-request type indicators."
  :group 'gh-notifications)

(defface gh-notifications-type-issue
  '((t :inherit magit-branch-local))
  "Face for issue type indicators."
  :group 'gh-notifications)

(defface gh-notifications-type-ci
  '((t :inherit magit-signature-untrusted))
  "Face for CI check-suite type indicators."
  :group 'gh-notifications)

(defface gh-notifications-type-release
  '((t :inherit magit-tag))
  "Face for release type indicators."
  :group 'gh-notifications)

(defface gh-notifications-type-discussion
  '((t :inherit magit-refname))
  "Face for discussion type indicators."
  :group 'gh-notifications)

(defface gh-notifications-type-other
  '((t :inherit magit-dimmed))
  "Face for unrecognised subject types."
  :group 'gh-notifications)

(defface gh-notifications-reason
  '((t :inherit magit-hash))
  "Face for notification reason labels."
  :group 'gh-notifications)

(defface gh-notifications-marked
  '((t :inherit magit-section-heading-selection))
  "Face for notifications marked for batch operations."
  :group 'gh-notifications)

(defface gh-notifications-keep
  '((t :inherit warning))
  "Face for notifications pinned to avoid reconciliation pruning."
  :group 'gh-notifications)

(defface gh-notifications-header-stats
  '((t :inherit magit-dimmed))
  "Face for the unread/total statistics in the buffer header."
  :group 'gh-notifications)

(defface gh-notifications-pr-merged
  '((t :inherit magit-cherry-equivalent))
  "Face for a merged pull request state indicator."
  :group 'gh-notifications)

(defface gh-notifications-pr-closed
  '((t :inherit magit-diff-removed))
  "Face for a closed (unmerged) pull request state indicator."
  :group 'gh-notifications)

(defface gh-notifications-pr-draft
  '((t :inherit magit-dimmed :slant italic))
  "Face for a draft pull request state indicator."
  :group 'gh-notifications)

;;; Internal state

(defvar gh-notifications--notifications nil
  "Alist of thread-id to notification struct for all fetched notifications.")

(defvar gh-notifications--saved nil
  "Alist of thread-id to notification struct for saved-for-later notifications.
Persisted to `gh-notifications-saved-file'.")

(defvar gh-notifications--saved-loaded nil
  "Non-nil once `gh-notifications--saved' has been loaded from disk.")

(defvar-local gh-notifications--view 'inbox
  "Which view the current buffer displays: `inbox' or `saved'.")

(defvar gh-notifications--marked nil
  "List of thread IDs currently marked for batch operations.")

(defvar gh-notifications--kept-ids nil
  "List of thread IDs pinned to survive reconciliation pruning.")

(defvar gh-notifications--poll-timer nil
  "Timer object for background polling.")

(defvar gh-notifications--poll-paused nil
  "When non-nil, automatic polling is paused.")

(defvar gh-notifications--filter-text ""
  "Current text filter substring.")

(defvar gh-notifications--filter-unread-only nil
  "When non-nil, show only unread notifications.")

(defvar gh-notifications--filter-types nil
  "List of subject type strings to include, or nil for all types.")

(defvar gh-notifications--filter-repos nil
  "List of owner/repo strings to include, or nil for all repos.")

(defvar gh-notifications--filter-ci-conclusions nil
  "List of CI conclusion strings to include, or nil to show all CI notifications.
Known values: success failure neutral cancelled skipped timed_out action_required.")

(defvar gh-notifications--filter-hide-ci nil
  "When non-nil, CheckSuite notifications are hidden entirely.")

(defvar gh-notifications--filter-hide-automation-and-ci nil
  "When non-nil, hide CheckSuite and rule-matched automation notifications.")

(defvar gh-notifications--filter-hide-renovate nil
  "When non-nil, hide PullRequest notifications authored by Renovate.
Authorship is matched against `gh-notifications-renovate-logins' using the
augmented author login.  Notifications whose author is not yet augmented are
shown until augmentation resolves.")

(defvar gh-notifications--filter-users nil
  "List of GitHub login strings.
When non-nil, only notifications involving at least one of these users
(as author, assignee, or requested reviewer) are shown.")

(defvar gh-notifications--augmentations (make-hash-table :test #'equal)
  "Hash table mapping thread-id strings to augmentation plists.
Each plist may contain: :ci-conclusion :author :assignees :reviewers :fetched.")

(defvar gh-notifications--augment-queue nil
  "List of notification IDs queued for REST augmentation.")

(defvar gh-notifications--augment-inflight 0
  "Number of REST augmentation requests currently in flight.")

(defvar gh-notifications--action-ring nil
  "List of recent destructive actions available for local undo.
Each entry is a plist with keys :action (string) and :notification (struct).
Capped at `gh-notifications-action-ring-size' entries.")

(defvar gh-notifications--fetch-generation 0
  "Monotonic generation number for notification fetches.
Only callbacks from the latest generation may mutate local state.")

(defcustom gh-notifications-action-ring-size 20
  "Maximum number of recent actions stored for local undo."
  :type 'natnum
  :group 'gh-notifications)

;;; Notification data model

(cl-defstruct (gh-notifications-notification
               (:constructor gh-notifications-notification--make)
               (:copier nil))
  "A single GitHub notification thread."
  id
  unread
  reason
  updated-at
  subject-title
  subject-type
  subject-url
  repo-full-name
  repo-html-url
  local-saved)

(defun gh-notifications--ci-conclusion-from-title (title)
  "Derive a CI conclusion string from a CheckSuite notification TITLE.
GitHub encodes the conclusion in plain English in the notification title."
  (cond
   ((string-match-p (rx (or "succeeded" "passed" "success")) title) "success")
   ((string-match-p (rx (or "failed" "failing" "failure"))  title) "failure")
   ((string-match-p "timed out"                             title) "timed_out")
   ((string-match-p "action required"                       title) "action_required")
   ((string-match-p (rx (or "cancelled" "canceled"))        title) "cancelled")
   ((string-match-p "skipped"                               title) "skipped")
   ((string-match-p "neutral"                               title) "neutral")
   (t "unknown")))

(defun gh-notifications--parse (data)
  "Parse a single notification alist DATA into a `gh-notifications-notification'.
For CheckSuite notifications, the CI conclusion is derived from the title and
stored immediately in `gh-notifications--augmentations'."
  (let* ((subject (alist-get 'subject data))
         (repo    (alist-get 'repository data))
         (id      (alist-get 'id data))
         (type    (alist-get 'type subject))
         (title   (alist-get 'title subject)))
    (when (string= type "CheckSuite")
      (let* ((conclusion (gh-notifications--ci-conclusion-from-title (or title "")))
             (needs-pr   (member conclusion '("failure" "timed_out" "action_required"))))
        (puthash id (list :ci-conclusion conclusion
                          :fetched      (not needs-pr))
                 gh-notifications--augmentations)))
    (gh-notifications-notification--make
     :id             id
     :unread         (eq (alist-get 'unread data) t)
     :reason         (alist-get 'reason data)
     :updated-at     (alist-get 'updated_at data)
     :subject-title  title
     :subject-type   type
     :subject-url    (alist-get 'url subject)
     :repo-full-name (alist-get 'full_name repo)
     :repo-html-url  (alist-get 'html_url repo)
     :local-saved    nil)))

;;; Authentication

(defvar gh-notifications--token-cache nil
  "Cached token returned by `gh auth token', or nil when not yet resolved.")

(defvar gh-notifications--login-cache nil
  "Cached GitHub login from `GET /user', or nil when not yet resolved.")

(defun gh-notifications--token ()
  "Return a GitHub API token by invoking `gh auth token'.
The result is cached for the lifetime of the Emacs session.
Signal a `user-error' when the gh CLI is unavailable or returns no token."
  (or gh-notifications--token-cache
      (let ((raw (string-trim
                  (shell-command-to-string "gh auth token 2>/dev/null"))))
        (if (string-empty-p raw)
            (user-error
             "gh auth token returned nothing; run `gh auth login' first")
          (setq gh-notifications--token-cache raw)))))

(defun gh-notifications-clear-token-cache ()
  "Clear cached authentication identity and token.
Forces fresh `gh auth token' and `GET /user' calls."
  (interactive)
  (setq gh-notifications--token-cache nil
        gh-notifications--login-cache nil)
  (message "gh-notifications: token and login cache cleared"))

;;; Augmentation

(defun gh-notifications--derive-pr-state (data)
  "Derive a concise PR state string from PR REST response DATA.
Returns one of: \"merged\" \"closed\" \"draft\" \"open\"."
  (cond
   ((eq  (alist-get 'merged data) t)           "merged")
   ((string= (alist-get 'state data) "closed") "closed")
   ((eq  (alist-get 'draft  data) t)           "draft")
   (t                                           "open")))

(defun gh-notifications--ci-branch-from-title (title)
  "Extract the head branch name from a CheckSuite notification TITLE.
GitHub titles follow the pattern \"… for BRANCH branch\".
Returns nil when the pattern is not found."
  (when (string-match (rx " for " (group (+ (not space))) " branch" eos) title)
    (match-string 1 title)))

(defun gh-notifications--ci-workflow-from-title (title)
  "Extract the workflow name from a CheckSuite notification TITLE.
GitHub titles follow the pattern \"WORKFLOW workflow run …\" where WORKFLOW
is the `name:' field from the workflow definition.  Returns nil when the
pattern is not found."
  (when (string-match (rx bos (group (+? anything)) " workflow run") title)
    (match-string 1 title)))

(defun gh-notifications--augment-finish (id)
  "Decrement the inflight counter for ID and continue draining or re-render."
  (setq gh-notifications--augment-inflight
        (max 0 (1- gh-notifications--augment-inflight)))
  (if gh-notifications--augment-queue
      (gh-notifications--augment-run-queue)
    (when (and (= gh-notifications--augment-inflight 0)
               (buffer-live-p (get-buffer gh-notifications--buffer-name)))
      (gh-notifications--render))))

(defun gh-notifications-reset-augmentation ()
  "Reset the augmentation queue and inflight counter, then re-augment all visible notifications.
Use this when augmentation appears stalled after network errors."
  (interactive)
  (setq gh-notifications--augment-queue    nil
        gh-notifications--augment-inflight 0)
  (gh-notifications--augment-visible)
  (message "gh-notifications: augmentation reset (%d items queued)"
           (length gh-notifications--augment-queue)))

(defun gh-notifications--augment-store-pr (id data)
  "Store PR augmentation from REST response DATA for thread ID.
Merges with any existing augmentation so :ci-conclusion is preserved.
Only sets :fetched when DATA contains a user login; otherwise the entry
is re-queued on the next render so we retry rather than pinning a partial
result."
  (let* ((existing (gethash id gh-notifications--augmentations))
         (login    (alist-get 'login (alist-get 'user data)))
         (usable   (and login t))
         (aug (list :author    login
                    :assignees (mapcar (lambda (a) (alist-get 'login a))
                                       (alist-get 'assignees data))
                    :reviewers (mapcar (lambda (r) (alist-get 'login r))
                                       (alist-get 'requested_reviewers data))
                    :pr-state  (gh-notifications--derive-pr-state data)
                    :fetched   usable))
         (merged (copy-sequence aug))
         (tail   existing))
    (while tail
      (let ((k (car tail)) (v (cadr tail)))
        (unless (plist-get aug k)
          (setq merged (plist-put merged k v))))
      (setq tail (cddr tail)))
    (puthash id merged gh-notifications--augmentations)))

(defun gh-notifications--augment-fetch-pr-issue (id n)
  "Fetch augmentation for a PullRequest or Issue notification N with thread ID."
  (cl-incf gh-notifications--augment-inflight)
  (gh-notifications--without-keepalive
    (ghub-get (replace-regexp-in-string
               (rx "https://api.github.com") ""
               (gh-notifications-notification-subject-url n))
              nil
              :host gh-notifications-host
              :auth 'none
              :headers (gh-notifications--auth-headers)
              :callback
              (lambda (data _headers _status _req)
                (gh-notifications--augment-store-pr id data)
                (gh-notifications--augment-finish id))
              :errorback
              (lambda (_err _headers _status _req)
                (gh-notifications--augment-finish id)))))

(defun gh-notifications--augment-fetch-ci-pr (id n)
  "Search for the PR associated with a failed CheckSuite notification N with thread ID."
  (let* ((title  (gh-notifications-notification-subject-title n))
         (branch (gh-notifications--ci-branch-from-title (or title "")))
         (repo   (gh-notifications-notification-repo-full-name n))
         (owner  (car (split-string repo "/"))))
    (when branch
      (cl-incf gh-notifications--augment-inflight)
      (gh-notifications--without-keepalive
        (ghub-get (format "/repos/%s/pulls" repo)
                  `((head     . ,(format "%s:%s" owner branch))
                    (state    . "all")
                    (per_page . "1"))
                  :host gh-notifications-host
                  :auth 'none
                  :headers (gh-notifications--auth-headers)
                  :callback
                  (lambda (data _headers _status _req)
                    (when (car data)
                      (gh-notifications--augment-store-pr id (car data)))
                    (let* ((existing (gethash id gh-notifications--augmentations))
                           (updated  (plist-put (copy-sequence existing) :fetched t)))
                      (puthash id updated gh-notifications--augmentations))
                    (gh-notifications--augment-finish id))
                  :errorback
                  (lambda (_err _headers _status _req)
                    (gh-notifications--augment-finish id)))))))

(defun gh-notifications--augment-run-queue ()
  "Drain `gh-notifications--augment-queue' up to `gh-notifications-augment-concurrency'.
Each dequeued ID is dispatched to the appropriate fetch helper depending on
subject type."
  (while (and gh-notifications--augment-queue
              (< gh-notifications--augment-inflight
                 gh-notifications-augment-concurrency))
    (let* ((id   (pop gh-notifications--augment-queue))
           (n    (alist-get id gh-notifications--notifications nil nil #'equal))
           (type (and n (gh-notifications-notification-subject-type n))))
      (cond
       ((member type '("PullRequest" "Issue"))
        (gh-notifications--augment-fetch-pr-issue id n))
       ((string= type "CheckSuite")
        (gh-notifications--augment-fetch-ci-pr id n))))))

(defun gh-notifications--queue-augmentation (n)
  "Enqueue notification N for REST augmentation if not already fetched or queued.
Queues PullRequest and Issue notifications for direct subject-URL fetch.
Queues failed CheckSuite notifications for PR branch-search fetch."
  (let* ((id     (gh-notifications-notification-id n))
         (type   (gh-notifications-notification-subject-type n))
         (aug    (gethash id gh-notifications--augmentations))
         (queued (member id gh-notifications--augment-queue)))
    (unless (or (plist-get aug :fetched) queued)
      (cond
       ((and (member type '("PullRequest" "Issue"))
             (gh-notifications-notification-subject-url n))
        (push id gh-notifications--augment-queue))
       ((and (string= type "CheckSuite")
             (member (plist-get aug :ci-conclusion) '("failure" "timed_out" "action_required"))
             (gh-notifications--ci-branch-from-title
              (or (gh-notifications-notification-subject-title n) "")))
        (push id gh-notifications--augment-queue))))))

(defun gh-notifications--augment-visible ()
  "Queue augmentation for all currently visible notifications that lack user data.
Called after every render so that PR and Issue notifications are always
augmented, regardless of whether a filter is active."
  (dolist (pair (gh-notifications--filtered-notifications))
    (gh-notifications--queue-augmentation (cdr pair)))
  (when gh-notifications--augment-queue
    (gh-notifications--augment-run-queue)))

;;; GitHub API

(defmacro gh-notifications--without-keepalive (&rest body)
  "Evaluate BODY with HTTP keep-alive disabled.
`url-http' reads `url-http-attempt-keepalives' synchronously when initiating
a request, so a `let' binding here is sufficient even for async calls."
  (declare (indent 0))
  `(let ((url-http-attempt-keepalives nil))
     ,@body))

(defun gh-notifications--auth-headers ()
  "Return the HTTP headers required for GitHub API authentication."
  (list (cons "Authorization"        (concat "Bearer " (gh-notifications--token)))
        (cons "X-GitHub-Api-Version" "2022-11-28")
        (cons "Cache-Control"        "no-store")))

(defun gh-notifications--fetch (&optional callback silent)
  "Fetch all notification pages from GitHub and update internal state.
When CALLBACK is non-nil, call it with no arguments after the fetch
completes.
When SILENT is non-nil, fetch errors are logged to `*Messages*' without
echo-area display.  Used by the background poll to avoid interrupting
interaction.
If multiple fetches overlap, only the newest fetch may update local state."
  (let ((results nil)
        (full-fetch t)
        (generation (cl-incf gh-notifications--fetch-generation)))
    (cl-labels
        ((current-fetch-p ()
           (= generation gh-notifications--fetch-generation))
         (finish ()
           (when (current-fetch-p)
             (gh-notifications--store-results results full-fetch)
             (when callback (funcall callback))))
         (fetch-page (page)
           (gh-notifications--without-keepalive
             (ghub-get "/notifications"
                       `((all . ,(if gh-notifications-fetch-all "true" "false"))
                         (per_page . "50")
                         (page . ,page))
                       :host gh-notifications-host
                       :auth 'none
                       :headers (gh-notifications--auth-headers)
                       :callback
                       (lambda (data headers _status _req)
                         (when (current-fetch-p)
                           (if (null data)
                               (finish)
                             (setq results
                                   (append results
                                           (mapcar #'gh-notifications--parse data)))
                             (if (gh-notifications--has-next-page-p headers)
                                 (if (< page gh-notifications-max-pages)
                                     (fetch-page (1+ page))
                                   (setq full-fetch nil)
                                   (finish))
                               (finish)))))
                       :errorback
                       (lambda (err _headers _status _req)
                         (when (current-fetch-p)
                           (let ((inhibit-message silent))
                             (message "gh-notifications: fetch error: %s" err))))))))
      (fetch-page 1))))

(defun gh-notifications--has-next-page-p (headers)
  "Return non-nil when HEADERS contain a Link header advertising a next page."
  (when-let* ((link (alist-get "Link" headers nil nil #'equal)))
    (string-match-p "rel=\"next\"" link)))

(defun gh-notifications--repo-full-name-from-api-url (api-url)
  "Extract owner/repo from API-URL, or nil when it cannot be parsed."
  (when (string-match
         (rx "https://api.github.com/repos/"
             (group (+ (not "/"))) "/"
             (group (+ (not "/"))) eos)
         api-url)
    (format "%s/%s" (match-string 1 api-url) (match-string 2 api-url))))

(defun gh-notifications--parse-my-pr (item)
  "Convert Search API ITEM into a `gh-notifications-notification'."
  (let* ((id-num      (alist-get 'id item))
         (id          (format "mine-%s" id-num))
         (repo-full   (gh-notifications--repo-full-name-from-api-url
                       (or (alist-get 'repository_url item) "")))
         (repo-html   (and repo-full (format "https://github.com/%s" repo-full)))
         (subject-url (or (alist-get 'url (alist-get 'pull_request item))
                          (alist-get 'url item))))
    (gh-notifications-notification--make
     :id             id
     :unread         nil
     :reason         "author"
     :updated-at     (alist-get 'updated_at item)
     :subject-title  (alist-get 'title item)
     :subject-type   "PullRequest"
     :subject-url    subject-url
     :repo-full-name repo-full
     :repo-html-url  repo-html
     :local-saved    nil)))

(defun gh-notifications--store-my-pr-results (notifications)
  "Replace `gh-notifications--mine' with NOTIFICATIONS.
Preserves local save markers when IDs already exist in the current list."
  (let ((previous gh-notifications--mine)
        (next nil))
    (dolist (n notifications)
      (let* ((id (gh-notifications-notification-id n))
             (existing (alist-get id previous nil nil #'equal)))
        (when existing
          (setf (gh-notifications-notification-local-saved n)
                (gh-notifications-notification-local-saved existing)))
        (push (cons id n) next)))
    (setq gh-notifications--mine next)))

(defun gh-notifications--my-prs-query-for-login (login)
  "Return the Search API query for LOGIN using `gh-notifications-my-prs-query'."
  (if (string-match-p "%s" gh-notifications-my-prs-query)
      (format gh-notifications-my-prs-query login)
    (string-trim (format "%s author:%s" gh-notifications-my-prs-query login))))

(defun gh-notifications--fetch-login (callback &optional silent)
  "Resolve the current GitHub login and pass it to CALLBACK.
When SILENT is non-nil, suppress echo-area noise for fetch errors."
  (if gh-notifications--login-cache
      (funcall callback gh-notifications--login-cache)
    (gh-notifications--without-keepalive
      (ghub-get "/user"
                nil
                :host gh-notifications-host
                :auth 'none
                :headers (gh-notifications--auth-headers)
                :callback
                (lambda (data _headers _status _req)
                  (let ((login (alist-get 'login data)))
                    (setq gh-notifications--login-cache login)
                    (funcall callback login)))
                :errorback
                (lambda (err _headers _status _req)
                  (let ((inhibit-message silent))
                    (message "gh-notifications: failed to resolve login: %s" err))
                  (funcall callback nil))))))

(defun gh-notifications--fetch-my-prs (&optional callback silent)
  "Fetch authored pull requests and update `gh-notifications--mine'.
When CALLBACK is non-nil, call it with no arguments after completion.
When SILENT is non-nil, log errors without echo-area interruption."
  (gh-notifications--fetch-login
   (lambda (login)
     (if (not login)
         (when callback (funcall callback))
       (let ((results nil)
             (query (gh-notifications--my-prs-query-for-login login)))
         (cl-labels
             ((fetch-page (page)
                (gh-notifications--without-keepalive
                  (ghub-get "/search/issues"
                            `((q        . ,query)
                              (sort     . "updated")
                              (order    . "desc")
                              (per_page . "100")
                              (page     . ,(number-to-string page)))
                            :host gh-notifications-host
                            :auth 'none
                            :headers (gh-notifications--auth-headers)
                            :callback
                            (lambda (data headers _status _req)
                              (let ((items (alist-get 'items data)))
                                (setq results
                                      (append results
                                              (mapcar #'gh-notifications--parse-my-pr items)))
                                (if (and items
                                         (gh-notifications--has-next-page-p headers)
                                         (< page gh-notifications-my-prs-max-pages))
                                    (fetch-page (1+ page))
                                  (gh-notifications--store-my-pr-results results)
                                  (when callback (funcall callback)))))
                            :errorback
                            (lambda (err _headers _status _req)
                              (let ((inhibit-message silent))
                                (message "gh-notifications: my-prs fetch error: %s" err))
                              (when callback (funcall callback)))))))
           (fetch-page 1)))))
   silent))

(defun gh-notifications--invalidate-augmentation (id n)
  "Clear the :fetched flag in the augmentation cache for PR or Issue ID.
Called when the notification's updated-at timestamp has changed, indicating
the underlying resource may have a new state."
  (when (member (gh-notifications-notification-subject-type n)
                '("PullRequest" "Issue"))
    (when-let* ((aug (gethash id gh-notifications--augmentations)))
      (puthash id (plist-put (copy-sequence aug) :fetched nil)
               gh-notifications--augmentations))))

(defun gh-notifications--store-results (notifications &optional full-fetch)
  "Merge freshly fetched NOTIFICATIONS into `gh-notifications--notifications'.
Updates existing entries with fresh API data and preserves local markers.
Invalidates PR/Issue augmentation when updated-at has changed so the next
render re-fetches the current state.
When FULL-FETCH and `gh-notifications-prune-missing-after-fetch' are non-nil,
prune local inbox notifications missing from NOTIFICATIONS unless their IDs
are in `gh-notifications--kept-ids'."
  (dolist (n notifications)
    (let ((id (gh-notifications-notification-id n)))
      (if-let* ((existing (alist-get id gh-notifications--notifications
                                     nil nil #'equal)))
          (progn
            (setf (gh-notifications-notification-local-saved n)
                  (gh-notifications-notification-local-saved existing))
            (unless (equal (gh-notifications-notification-updated-at n)
                           (gh-notifications-notification-updated-at existing))
              (gh-notifications--invalidate-augmentation id n))
            (setf (alist-get id gh-notifications--notifications nil nil #'equal) n))
        (push (cons id n) gh-notifications--notifications))))
  (when (and full-fetch gh-notifications-prune-missing-after-fetch)
    (gh-notifications--reconcile-prune-missing notifications))
  (when gh-notifications-auto-mark-done-days
    (gh-notifications--auto-mark-done)))

(defun gh-notifications--reconcile-prune-missing (notifications)
  "Remove local inbox notifications absent from NOTIFICATIONS.
Notifications in `gh-notifications--kept-ids' are retained."
  (let ((remote-ids (make-hash-table :test #'equal)))
    (dolist (n notifications)
      (puthash (gh-notifications-notification-id n) t remote-ids))
    (setq gh-notifications--notifications
          (cl-remove-if
           (lambda (pair)
             (let* ((n (cdr pair))
                    (id (gh-notifications-notification-id n)))
               (and (not (member id gh-notifications--kept-ids))
                    (not (gethash id remote-ids)))))
           gh-notifications--notifications))))

(defun gh-notifications--auto-mark-done ()
  "Mark done any notifications older than `gh-notifications-auto-mark-done-days'."
  (let ((cutoff (- (float-time)
                   (* gh-notifications-auto-mark-done-days 86400))))
    (dolist (pair gh-notifications--notifications)
      (let* ((n       (cdr pair))
             (updated (gh-notifications-notification-updated-at n))
             (ts      (when updated (float-time (date-to-time updated)))))
        (when (and ts (< ts cutoff))
          (gh-notifications--api-mark-done
           (gh-notifications-notification-id n) nil))))))

;;; Per-notification API actions

(defun gh-notifications--api-mark-done (id &optional callback)
  "Delete notification thread ID on GitHub.
Call CALLBACK with no arguments when the request completes."
  (gh-notifications--without-keepalive
    (ghub-delete (format "/notifications/threads/%s" id)
                 nil
                 :host gh-notifications-host
                 :auth 'none
                 :headers (gh-notifications--auth-headers)
                 :callback (lambda (_data _headers _status _req)
                             (setq gh-notifications--notifications
                                   (assoc-delete-all id
                                                     gh-notifications--notifications
                                                     #'equal)
                                   gh-notifications--kept-ids
                                   (delete id gh-notifications--kept-ids))
                             (when callback (funcall callback))))))

(defun gh-notifications--api-mark-read (id &optional callback)
  "Mark notification thread ID as read on GitHub.
Call CALLBACK with no arguments when the request completes."
  (gh-notifications--without-keepalive
    (ghub-patch (format "/notifications/threads/%s" id)
                nil
                :host gh-notifications-host
                :auth 'none
                :headers (gh-notifications--auth-headers)
                :callback (lambda (_data _headers _status _req)
                            (when-let* ((n (alist-get id
                                                      gh-notifications--notifications
                                                      nil nil #'equal)))
                              (setf (gh-notifications-notification-unread n) nil))
                            (when callback (funcall callback))))))

(defun gh-notifications--api-unsubscribe (id &optional callback)
  "Unsubscribe from notification thread ID and mark it done on GitHub.
Call CALLBACK with no arguments when both requests complete."
  (gh-notifications--without-keepalive
    (ghub-delete (format "/notifications/threads/%s/subscription" id)
                 nil
                 :host gh-notifications-host
                 :auth 'none
                 :headers (gh-notifications--auth-headers)
                 :callback (lambda (_data _headers _status _req)
                             (gh-notifications--api-mark-done id callback)))))

(defun gh-notifications--api-close-pr-and-delete-branch (id &optional callback)
  "Close PullRequest notification thread ID and delete its head branch.
Marks the notification done when the close step succeeds.
If branch deletion returns HTTP 404 or 422, continue as success.
Call CALLBACK with no arguments when processing completes."
  (if-let* ((n       (alist-get id gh-notifications--notifications nil nil #'equal))
            (api-url (gh-notifications-notification-subject-url n)))
      (gh-notifications--without-keepalive
        (ghub-get (replace-regexp-in-string
                   (rx "https://api.github.com") ""
                   api-url)
                  nil
                  :host gh-notifications-host
                  :auth 'none
                  :headers (gh-notifications--auth-headers)
                  :callback
                  (lambda (data _headers _status _req)
                    (let* ((state     (alist-get 'state data))
                           (number    (alist-get 'number data))
                           (base-repo (alist-get 'full_name
                                                 (alist-get 'repo
                                                            (alist-get 'base data))))
                           (head-ref  (alist-get 'ref (alist-get 'head data)))
                           (head-repo (alist-get 'full_name
                                                 (alist-get 'repo
                                                            (alist-get 'head data)))))
                      (if (not (string= state "open"))
                          (gh-notifications--api-mark-done id callback)
                        (ghub-patch (format "/repos/%s/pulls/%s" base-repo number)
                                    `((state . "closed"))
                                    :host gh-notifications-host
                                    :auth 'none
                                    :headers (gh-notifications--auth-headers)
                                    :callback
                                    (lambda (_close-data _close-headers _close-status _close-req)
                                      (cl-labels
                                          ((finish ()
                                             (gh-notifications--api-mark-done id callback)))
                                        (if (and head-repo head-ref)
                                            (ghub-delete
                                             (format "/repos/%s/git/refs/heads/%s"
                                                     head-repo
                                                     (url-hexify-string head-ref))
                                             nil
                                             :host gh-notifications-host
                                             :auth 'none
                                             :headers (gh-notifications--auth-headers)
                                             :callback
                                             (lambda (_delete-data _delete-headers _delete-status _delete-req)
                                               (finish))
                                             :errorback
                                             (lambda (_err _delete-headers delete-status _delete-req)
                                               (if (member delete-status '(404 422))
                                                   (finish)
                                                 (message "gh-notifications: failed to delete branch for %s (HTTP %s)"
                                                          id delete-status)
                                                 (when callback (funcall callback)))))
                                          (finish))))
                                    :errorback
                                    (lambda (_err _close-headers close-status _close-req)
                                      (message "gh-notifications: failed to close PR for %s (HTTP %s)"
                                               id close-status)
                                      (when callback (funcall callback)))))))
                  :errorback
                  (lambda (_err _headers status _req)
                    (message "gh-notifications: failed to load PR data for %s (HTTP %s)"
                             id status)
                    (when callback (funcall callback))))))
  (when callback (funcall callback)))

;;; Subject URL resolution

(defun gh-notifications--subject-html-url (notification)
  "Return a browser-navigable URL for NOTIFICATION's subject.
For CheckSuite notifications, prefer any cached `:ci-run-url' from
augmentation, then a branch-filtered Actions search URL, then the repo URL."
  (let* ((api-url  (gh-notifications-notification-subject-url notification))
         (repo-url (gh-notifications-notification-repo-html-url notification))
         (type     (gh-notifications-notification-subject-type notification)))
    (cond
     ((string= type "CheckSuite")
      (gh-notifications--ci-html-url notification))
     ((null api-url) repo-url)
     ((string= type "PullRequest")
      (gh-notifications--api-url->html api-url "pull"))
     ((string= type "Issue")
      (gh-notifications--api-url->html api-url "issues"))
     ((string= type "Release")
      (gh-notifications--api-url->html api-url "releases/tag"))
     ((string= type "Discussion") repo-url)
     (t api-url))))

(defun gh-notifications--ci-html-url (n)
  "Return the best-effort browser URL for CheckSuite notification N.
Prefers a cached workflow run URL from augmentation.
Falls back to a branch-filtered Actions search URL when the branch can be
parsed from the notification title.  Falls back further to the repo URL."
  (let* ((id       (gh-notifications-notification-id n))
         (aug      (gethash id gh-notifications--augmentations))
         (run-url  (plist-get aug :ci-run-url))
         (repo     (gh-notifications-notification-repo-full-name n))
         (repo-url (gh-notifications-notification-repo-html-url n))
         (branch   (gh-notifications--ci-branch-from-title
                    (or (gh-notifications-notification-subject-title n) ""))))
    (cond
     (run-url run-url)
     ((and repo branch)
      (format "https://github.com/%s/actions?query=%s"
              repo
              (url-hexify-string (format "branch:%s" branch))))
     (t repo-url))))

(defun gh-notifications--api-url->html (api-url path-segment)
  "Convert an API-style resource URL to a GitHub browser URL using PATH-SEGMENT."
  (when (string-match
         (rx "https://api.github.com/repos/"
             (group (+ (not "/"))) "/"
             (group (+ (not "/"))) "/"
             (+ (not "/")) "/"
             (group (+ digit)))
         api-url)
    (format "https://github.com/%s/%s/%s/%s"
            (match-string 1 api-url)
            (match-string 2 api-url)
            path-segment
            (match-string 3 api-url))))

;;; Filtering

(defun gh-notifications--filtered-notifications ()
  "Return the subset of the current view's alist that passes all active filters."
  (seq-filter (lambda (pair)
                (gh-notifications--passes-filters-p (cdr pair)))
              (gh-notifications--current-alist)))

(defun gh-notifications--passes-filters-p (n)
  "Return non-nil when notification N satisfies every active filter."
  (and (or (not gh-notifications--filter-unread-only)
           (gh-notifications-notification-unread n))
       (or (string-empty-p gh-notifications--filter-text)
           (gh-notifications--text-match-p n gh-notifications--filter-text))
       (or (null gh-notifications--filter-types)
           (member (gh-notifications-notification-subject-type n)
                   gh-notifications--filter-types))
       (or (null gh-notifications--filter-repos)
           (member (gh-notifications-notification-repo-full-name n)
                   gh-notifications--filter-repos))
       (gh-notifications--passes-ci-filter-p n)
       (gh-notifications--passes-automation-and-ci-filter-p n)
       (gh-notifications--passes-renovate-filter-p n)
       (gh-notifications--passes-user-filter-p n)))

(defun gh-notifications--passes-ci-filter-p (n)
  "Return non-nil when N passes the active CI filters.
`gh-notifications--filter-hide-ci' hides all CheckSuite notifications.
`gh-notifications--filter-ci-conclusions' restricts to specific conclusions
and hides all non-CheckSuite notifications."
  (let ((is-ci (string= (gh-notifications-notification-subject-type n) "CheckSuite")))
    (and (not (and gh-notifications--filter-hide-ci is-ci))
         (or (null gh-notifications--filter-ci-conclusions)
             (and is-ci
                  (let* ((aug (gethash (gh-notifications-notification-id n)
                                       gh-notifications--augmentations))
                         (conclusion (plist-get aug :ci-conclusion)))
                    (member conclusion gh-notifications--filter-ci-conclusions)))))))

(defun gh-notifications--automation-notification-p (n)
  "Return non-nil when N matches any automation sweep rule.
Only PullRequest notifications are considered automation notifications."
  (and (string= (gh-notifications-notification-subject-type n) "PullRequest")
       (seq-some (lambda (rule)
                   (and (gh-notifications--sweep-rule-repo-match-p rule n)
                        (gh-notifications--sweep-rule-title-match-p rule n)))
                 gh-notifications-sweep-rules)))

(defun gh-notifications--passes-automation-and-ci-filter-p (n)
  "Return non-nil when N passes the automation-and-CI hide filter."
  (or (not gh-notifications--filter-hide-automation-and-ci)
      (and (not (string= (gh-notifications-notification-subject-type n)
                         "CheckSuite"))
           (not (gh-notifications--automation-notification-p n)))))

(defun gh-notifications--renovate-notification-p (n)
  "Return non-nil when N is a PullRequest authored by Renovate.
Authorship comes from the augmented author login.  Returns nil when the
author has not been augmented yet."
  (and (string= (gh-notifications-notification-subject-type n) "PullRequest")
       (let* ((aug    (gethash (gh-notifications-notification-id n)
                               gh-notifications--augmentations))
              (author (plist-get aug :author)))
         (and author
              (member author gh-notifications-renovate-logins)
              t))))

(defun gh-notifications--passes-renovate-filter-p (n)
  "Return non-nil when N passes the hide-Renovate filter."
  (or (not gh-notifications--filter-hide-renovate)
      (not (gh-notifications--renovate-notification-p n))))

(defun gh-notifications--passes-user-filter-p (n)
  "Return non-nil when N passes the active user filter.
Notifications whose type has no user data (CheckSuite, Release) always pass.
PR and Issue notifications pass when at least one of their author, assignees,
or requested reviewers appears in `gh-notifications--filter-users'."
  (or (null gh-notifications--filter-users)
      (not (member (gh-notifications-notification-subject-type n)
                   '("PullRequest" "Issue")))
      (let* ((aug       (gethash (gh-notifications-notification-id n)
                                 gh-notifications--augmentations))
             (author    (plist-get aug :author))
             (assignees (plist-get aug :assignees))
             (reviewers (plist-get aug :reviewers))
             (all       (delete nil (cons author (append assignees reviewers)))))
        (seq-some (lambda (login) (member login gh-notifications--filter-users))
                  all))))

(defun gh-notifications--text-match-p (n text)
  "Return non-nil when TEXT is a case-insensitive substring of any searchable field of N."
  (let ((case-fold-search t)
        (pattern (regexp-quote text)))
    (or (and (gh-notifications-notification-subject-title n)
             (string-match-p pattern
                             (gh-notifications-notification-subject-title n)))
        (and (gh-notifications-notification-repo-full-name n)
             (string-match-p pattern
                             (gh-notifications-notification-repo-full-name n)))
        (and (gh-notifications-notification-reason n)
             (string-match-p pattern
                             (gh-notifications-notification-reason n))))))

(defun gh-notifications--updated-at-seconds (n)
  "Return the updated-at timestamp of N as a float, or 0.0 if absent."
  (let ((ts (gh-notifications-notification-updated-at n)))
    (if ts (float-time (date-to-time ts)) 0.0)))

(defun gh-notifications--grouped-notifications ()
  "Return filtered notifications as an alist of repo-full-name to notification list.
Repos are sorted alphabetically.  Notifications within each repo are sorted
by updated-at descending (most recent first)."
  (let ((groups nil))
    (dolist (pair (gh-notifications--filtered-notifications))
      (let* ((n    (cdr pair))
             (repo (gh-notifications-notification-repo-full-name n))
             (cell (assoc repo groups)))
        (if cell
            (push n (cdr cell))
          (push (list repo n) groups))))
    (dolist (group groups)
      (setcdr group (sort (cdr group)
                          (lambda (a b)
                            (> (gh-notifications--updated-at-seconds a)
                               (gh-notifications--updated-at-seconds b))))))
    (sort groups (lambda (a b) (string< (car a) (car b))))))

;;; Display helpers

(defun gh-notifications--type-indicator (type)
  "Return a propertized symbol and label string for subject TYPE."
  (pcase type
    ("PullRequest" (propertize "" 'font-lock-face 'gh-notifications-type-pr
                               'help-echo "Pull request"))
    ("Issue"       (propertize "" 'font-lock-face 'gh-notifications-type-issue
                               'help-echo "Issue"))
    ("CheckSuite"  (propertize "" 'font-lock-face 'gh-notifications-type-ci
                               'help-echo "CI check suite"))
    ("Release"     (propertize "" 'font-lock-face 'gh-notifications-type-release
                               'help-echo "Release"))
    ("Discussion"  (propertize "" 'font-lock-face 'gh-notifications-type-discussion
                               'help-echo "Discussion"))
    (_             (propertize "·" 'font-lock-face 'gh-notifications-type-other))))

(defun gh-notifications--reason-abbreviation (reason)
  "Return a short display label for a GitHub notification REASON string."
  (pcase reason
    ("review_requested"   "review")
    ("assign"             "assigned")
    ("author"             "author")
    ("comment"            "comment")
    ("mention"            "mention")
    ("team_mention"       "team")
    ("state_change"       "state")
    ("subscribed"         "subscribed")
    ("ci_activity"        "ci")
    ("security_alert"     "security")
    ("manual"             "manual")
    ("invitation"         "invitation")
    (_                    (or reason "?"))))

(defun gh-notifications--pr-state-indicator (pr-state)
  "Return a propertized state badge for PR-STATE, or nil when state is unknown."
  (pcase pr-state
    ("merged" (propertize "merged" 'font-lock-face 'gh-notifications-pr-merged))
    ("closed" (propertize "closed" 'font-lock-face 'gh-notifications-pr-closed))
    ("draft"  (propertize "draft"  'font-lock-face 'gh-notifications-pr-draft))
    ("open"   (propertize "open"   'font-lock-face 'magit-dimmed))
    (_        nil)))

(defun gh-notifications--old-p (notification)
  "Return non-nil when NOTIFICATION is older than `gh-notifications-older-than-days'."
  (when-let* ((updated (gh-notifications-notification-updated-at notification)))
    (< (float-time (date-to-time updated))
       (- (float-time) (* gh-notifications-older-than-days 86400)))))

;;; Buffer and sections

(defconst gh-notifications--buffer-name "*GitHub Notifications*"
  "Name of the inbox notifications list buffer.")

(defconst gh-notifications--saved-buffer-name "*GitHub Notifications: Saved*"
  "Name of the saved-for-later notifications list buffer.")

(defconst gh-notifications--mine-buffer-name "*GitHub Notifications: My PRs*"
  "Name of the authored pull requests list buffer.")

(defun gh-notifications--buffer-name-for (view)
  "Return the buffer name that holds VIEW (`inbox', `saved', or `mine')."
  (pcase view
    ('saved gh-notifications--saved-buffer-name)
    ('mine  gh-notifications--mine-buffer-name)
    (_      gh-notifications--buffer-name)))

(defun gh-notifications--buffer (&optional view)
  "Return the notifications buffer for VIEW, creating it if necessary.
VIEW defaults to `inbox'."
  (let* ((view (or view 'inbox))
         (name (gh-notifications--buffer-name-for view)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (gh-notifications-mode)
          (setq gh-notifications--view view)
          (current-buffer)))))

(defvar gh-notifications--mine nil
  "Alist of synthetic-id to notification struct for authored pull requests.")

(defun gh-notifications--current-alist ()
  "Return the notifications alist for the current view."
  (pcase gh-notifications--view
    ('saved gh-notifications--saved)
    ('mine  gh-notifications--mine)
    (_      gh-notifications--notifications)))

;;; Saved-for-later persistence

(defun gh-notifications--saved-ensure-loaded ()
  "Load `gh-notifications--saved' from disk on first use."
  (unless gh-notifications--saved-loaded
    (setq gh-notifications--saved-loaded t)
    (when (file-readable-p gh-notifications-saved-file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents gh-notifications-saved-file)
            (goto-char (point-min))
            (setq gh-notifications--saved (read (current-buffer))))
        (error
         (message "gh-notifications: failed to load %s: %s"
                  gh-notifications-saved-file err)
         (setq gh-notifications--saved nil))))))

(defun gh-notifications--saved-persist ()
  "Write `gh-notifications--saved' to `gh-notifications-saved-file'."
  (let ((dir (file-name-directory gh-notifications-saved-file)))
    (when (and dir (not (file-directory-p dir)))
      (make-directory dir t)))
  (with-temp-file gh-notifications-saved-file
    (let ((print-length nil)
          (print-level  nil)
          (print-circle nil))
      (prin1 gh-notifications--saved (current-buffer)))))

(defun gh-notifications--render ()
  "Redraw every live gh-notifications buffer.
Each buffer holds its own view via the buffer-local `gh-notifications--view'."
  (dolist (view '(inbox saved mine))
    (when-let* ((buf (get-buffer (gh-notifications--buffer-name-for view))))
      (with-current-buffer buf
        (gh-notifications--render-current-buffer)))))

(defun gh-notifications--render-current-buffer ()
  "Redraw the current gh-notifications-mode buffer using its view."
  (let ((inhibit-read-only t)
        (saved-point (point)))
    (erase-buffer)
    (magit-insert-section (gh-notifications-root)
      (gh-notifications--insert-header)
      (let ((groups (gh-notifications--grouped-notifications)))
        (if (null groups)
            (insert (propertize (pcase gh-notifications--view
                                  ('saved "  Nothing saved for later.\n")
                                  ('mine  "  No authored pull requests match the current filters.\n")
                                  (_      "  No notifications match the current filters.\n"))
                                'font-lock-face 'shadow))
          (dolist (group groups)
            (gh-notifications--insert-repo-section
             (car group) (cdr group))))))
    (goto-char (min saved-point (point-max))))
  (when (member gh-notifications--view '(inbox mine))
    (gh-notifications--augment-visible)))

(defun gh-notifications--insert-header ()
  "Insert the summary header into the current buffer."
  (let* ((source   (gh-notifications--current-alist))
         (total    (length source))
         (unread   (seq-count
                    (lambda (p)
                      (gh-notifications-notification-unread (cdr p)))
                    source))
         (kept     (seq-count
                    (lambda (p)
                      (member (car p) gh-notifications--kept-ids))
                    source))
         (filtered (length (gh-notifications--filtered-notifications)))
         (marked   (length gh-notifications--marked))
         (filtering-p (or (not (string-empty-p gh-notifications--filter-text))
                          gh-notifications--filter-unread-only
                          gh-notifications--filter-types
                          gh-notifications--filter-repos
                          gh-notifications--filter-hide-ci
                          gh-notifications--filter-hide-automation-and-ci
                          gh-notifications--filter-hide-renovate
                          gh-notifications--filter-ci-conclusions
                          gh-notifications--filter-users)))
    (insert (propertize (pcase gh-notifications--view
                          ('saved "GitHub Notifications — Saved for later")
                          ('mine  "GitHub Notifications — My pull requests")
                          (_      "GitHub Notifications"))
                        'font-lock-face 'magit-section-heading))
    (insert "  ")
    (insert (propertize (format "%d unread" unread) 'font-lock-face 'gh-notifications-unread))
    (insert (propertize (format " / %d total" total) 'font-lock-face 'gh-notifications-header-stats))
    (when (< filtered total)
      (insert (propertize (format "  %d shown" filtered)
                          'font-lock-face 'gh-notifications-header-stats)))
    (when (> marked 0)
      (insert "  ")
      (insert (propertize (format "%d marked" marked)
                          'font-lock-face 'gh-notifications-marked)))
    (when (> kept 0)
      (insert "  ")
      (insert (propertize (format "%d kept" kept)
                          'font-lock-face 'gh-notifications-keep)))
    (insert "\n")
    (when filtering-p
      (insert (propertize "Filters:" 'font-lock-face 'magit-section-secondary-heading))
      (unless (string-empty-p gh-notifications--filter-text)
        (insert (propertize "  text " 'font-lock-face 'magit-dimmed))
        (insert (propertize gh-notifications--filter-text 'font-lock-face 'magit-section-heading)))
      (when gh-notifications--filter-unread-only
        (insert (propertize "  unread only" 'font-lock-face 'magit-section-heading)))
      (when gh-notifications--filter-types
        (insert (propertize "  types " 'font-lock-face 'magit-dimmed))
        (insert (propertize (string-join gh-notifications--filter-types ",")
                            'font-lock-face 'magit-section-heading)))
      (when gh-notifications--filter-repos
        (insert (propertize "  repos " 'font-lock-face 'magit-dimmed))
        (insert (propertize (string-join gh-notifications--filter-repos ",")
                            'font-lock-face 'magit-section-heading)))
      (when gh-notifications--filter-hide-ci
        (insert (propertize "  ci hidden" 'font-lock-face 'gh-notifications-type-ci)))
      (when gh-notifications--filter-hide-automation-and-ci
        (insert (propertize "  human-only" 'font-lock-face 'magit-section-heading)))
      (when gh-notifications--filter-hide-renovate
        (insert (propertize "  renovate hidden" 'font-lock-face 'magit-section-heading)))
      (when gh-notifications--filter-ci-conclusions
        (insert (propertize "  ci " 'font-lock-face 'magit-dimmed))
        (insert (propertize (string-join gh-notifications--filter-ci-conclusions ",")
                            'font-lock-face 'gh-notifications-type-ci)))
      (when gh-notifications--filter-users
        (insert (propertize "  users " 'font-lock-face 'magit-dimmed))
        (insert (propertize (string-join gh-notifications--filter-users ",")
                            'font-lock-face 'magit-branch-local)))
      (insert "\n"))
    (insert "\n")))

(defun gh-notifications--insert-repo-section (repo notifications)
  "Insert a collapsible magit section for REPO containing NOTIFICATIONS."
  (magit-insert-section (gh-notifications-repo repo)
    (magit-insert-heading
      (propertize repo 'font-lock-face 'gh-notifications-repo)
      (propertize (format " (%d)" (length notifications))
                  'font-lock-face 'gh-notifications-count))
    (dolist (n notifications)
      (gh-notifications--insert-notification-line n))))

(defconst gh-notifications--title-width 50
  "Display width reserved for the notification title column.")

(defun gh-notifications--insert-notification-line (n)
  "Insert a single propertized line for notification N.
The notification struct is stored as the `gh-notification' text property
on the line so that `gh-notifications--notification-at-point' can retrieve it."
  (let* ((id     (gh-notifications-notification-id n))
         (unread (gh-notifications-notification-unread n))
         (marked (member id gh-notifications--marked))
         (kept   (member id gh-notifications--kept-ids))
         (old    (gh-notifications--old-p n))
         (title  (or (gh-notifications-notification-subject-title n) "(no title)"))
         (type   (gh-notifications-notification-subject-type n))
         (reason (gh-notifications--reason-abbreviation
                  (gh-notifications-notification-reason n)))
         (face   (cond (marked 'gh-notifications-marked)
                       (old    'gh-notifications-old)
                       (unread 'gh-notifications-unread)
                       (t      'gh-notifications-read)))
         (start  (point)))
    (insert (cond
             (marked (propertize "● " 'font-lock-face 'gh-notifications-marked))
             (kept   (propertize "★ " 'font-lock-face 'gh-notifications-keep))
             (t      "  ")))
    (insert (gh-notifications--type-indicator type))
    (insert " ")
    (insert (propertize (truncate-string-to-width title gh-notifications--title-width
                                                  nil ?\s "…")
                        'font-lock-face face))
    (insert " ")
    (insert (propertize (truncate-string-to-width reason 12 nil ?\s)
                        'font-lock-face 'gh-notifications-reason))
    (when-let* ((aug (gethash id gh-notifications--augmentations)))
      (let ((badge (gh-notifications--pr-state-indicator (plist-get aug :pr-state))))
        (insert (propertize (truncate-string-to-width (or badge "") 8 nil ?\s)
                            'font-lock-face (pcase (plist-get aug :pr-state)
                                              ("merged" 'gh-notifications-pr-merged)
                                              ("closed" 'gh-notifications-pr-closed)
                                              ("draft"  'gh-notifications-pr-draft)
                                              (_        'magit-dimmed)))))
      (when (member type '("PullRequest" "Issue"))
        (when-let* ((author (plist-get aug :author)))
          (insert (propertize (truncate-string-to-width author 22 nil ?\s "…")
                              'font-lock-face 'magit-log-author)))
        (when-let* ((reviewers (plist-get aug :reviewers)))
          (insert (propertize "→ " 'font-lock-face 'magit-dimmed))
          (insert (propertize (truncate-string-to-width (string-join reviewers " ") 30 nil ?\s "…")
                              'font-lock-face 'magit-branch-remote)))))
    (insert "\n")
    (put-text-property start (point) 'gh-notification n)))

;;; Interactive commands

(defun gh-notifications--push-action (action notifications &optional view)
  "Record ACTION on NOTIFICATIONS in `gh-notifications--action-ring'.
ACTION is a short string naming the operation.  NOTIFICATIONS is a list of
`gh-notifications-notification' structs representing the complete batch.
VIEW (`inbox' or `saved', default `inbox') identifies which alist the
notifications should be restored to on undo.
The ring is capped at `gh-notifications-action-ring-size'."
  (push (list :action action
              :notifications notifications
              :view (or view 'inbox))
        gh-notifications--action-ring)
  (when (> (length gh-notifications--action-ring)
           gh-notifications-action-ring-size)
    (setq gh-notifications--action-ring
          (seq-take gh-notifications--action-ring
                    gh-notifications-action-ring-size))))

(defun gh-notifications-undo ()
  "Restore all notifications from the most recent action as a single undo step.
This reverses the local view state only; the GitHub API change is not undone.
Each press of `Z' undoes one batch, regardless of how many notifications it
contained."
  (interactive)
  (if (null gh-notifications--action-ring)
      (user-error "gh-notifications: nothing to undo")
    (let* ((entry   (pop gh-notifications--action-ring))
           (action  (plist-get entry :action))
           (notifs  (plist-get entry :notifications))
           (view    (or (plist-get entry :view) 'inbox))
           (count   (length notifs)))
      (pcase view
        ('saved
         (dolist (n notifs)
           (let ((id (gh-notifications-notification-id n)))
             (unless (alist-get id gh-notifications--saved nil nil #'equal)
               (push (cons id n) gh-notifications--saved))))
         (gh-notifications--saved-persist))
        (_
         (dolist (n notifs)
           (let ((id (gh-notifications-notification-id n)))
             (unless (alist-get id gh-notifications--notifications nil nil #'equal)
               (push (cons id n) gh-notifications--notifications))))))
      (gh-notifications--render)
      (message "gh-notifications: restored %d notification(s) (undo of %s in %s%s)"
               count action view
               (if (eq view 'saved) "" " — GitHub state unchanged")))))

(defun gh-notifications-refresh ()
  "Refresh the notifications list from GitHub.
On a manual refresh, augmentation is invalidated for all currently visible
PR and Issue notifications so their state is re-fetched unconditionally.
The poll timer does not do this; it relies on updated-at changes instead."
  (interactive)
  (message "gh-notifications: fetching...")
  (dolist (pair (gh-notifications--filtered-notifications))
    (let* ((n  (cdr pair))
           (id (gh-notifications-notification-id n)))
      (gh-notifications--invalidate-augmentation id n)))
  (if (eq gh-notifications--view 'mine)
      (gh-notifications--fetch-my-prs
       (lambda ()
         (gh-notifications--render)
         (message "gh-notifications: done")))
    (gh-notifications--fetch
     (lambda ()
       (gh-notifications--render)
       (message "gh-notifications: done")))))

(defun gh-notifications-mark-done ()
  "Mark the notification at point as done.
In the inbox view this deletes the thread on GitHub.
In the saved view this removes the notification from the persisted store."
  (interactive)
  (cond
   ((eq gh-notifications--view 'saved)
    (gh-notifications-saved-remove-at-point))
   ((eq gh-notifications--view 'mine)
    (user-error "Mark done is unavailable in My PRs view"))
   (t
    (when-let* ((n (gh-notifications--notification-at-point)))
      (gh-notifications--push-action "mark-done" (list n) 'inbox)
      (gh-notifications--api-mark-done
       (gh-notifications-notification-id n)
       (lambda ()
         (gh-notifications--render)
         (message "gh-notifications: marked done (Z to undo locally)")))))))

(defun gh-notifications-mark-read ()
  "Mark the notification at point as read."
  (interactive)
  (when (eq gh-notifications--view 'mine)
    (user-error "Mark read is unavailable in My PRs view"))
  (when-let* ((n (gh-notifications--notification-at-point)))
    (gh-notifications--api-mark-read
     (gh-notifications-notification-id n)
     (lambda ()
       (gh-notifications--render)
       (message "gh-notifications: marked read")))))

(defun gh-notifications-unsubscribe ()
  "Unsubscribe from and mark done the notification at point."
  (interactive)
  (when (eq gh-notifications--view 'mine)
    (user-error "Unsubscribe is unavailable in My PRs view"))
  (when-let* ((n (gh-notifications--notification-at-point)))
    (gh-notifications--push-action "unsubscribe" (list n))
    (gh-notifications--api-unsubscribe
     (gh-notifications-notification-id n)
     (lambda ()
       (gh-notifications--render)
       (message "gh-notifications: unsubscribed (Z to undo locally)")))))

(defun gh-notifications-open ()
  "Open the notification at point in a browser and mark it read.
For CheckSuite notifications without a cached workflow run URL, first
resolve the latest run for the branch via the Actions API, cache the URL,
and then open it.  Falls back to the best-effort URL when the resolution
fails."
  (interactive)
  (when-let* ((n (gh-notifications--notification-at-point)))
    (let* ((type       (gh-notifications-notification-subject-type n))
           (id         (gh-notifications-notification-id n))
           (aug        (gethash id gh-notifications--augmentations))
           (title      (or (gh-notifications-notification-subject-title n) ""))
           (branch     (gh-notifications--ci-branch-from-title title))
           (workflow   (and (string= type "CheckSuite")
                            (gh-notifications--ci-workflow-from-title title)))
           (conclusion (and (string= type "CheckSuite")
                            (gh-notifications--ci-conclusion-from-title title)))
           (cached-url (plist-get aug :ci-run-url))
           (cached-cn  (plist-get aug :ci-run-conclusion))
           (cached-wf  (plist-get aug :ci-run-workflow))
           (cache-ok   (and cached-url
                            (equal cached-cn conclusion)
                            (equal cached-wf workflow)))
           (needs-resolve (and (string= type "CheckSuite")
                               branch
                               (not cache-ok))))
      (if needs-resolve
          (gh-notifications--resolve-ci-run-and-open n)
        (gh-notifications--open-notification n)))))

(defun gh-notifications--open-notification (n)
  "Open notification N in a browser and mark it read."
  (let ((url (gh-notifications--subject-html-url n)))
    (when url
      (browse-url url)
      (when (gh-notifications-notification-unread n)
        (gh-notifications--api-mark-read
         (gh-notifications-notification-id n)
         #'gh-notifications--render)))))

(defun gh-notifications--resolve-ci-run-and-open (n)
  "Resolve the matching Actions run URL for CheckSuite N, cache it, then open.
Filters `GET /actions/runs' by the conclusion derived from the notification
title so a subsequent skipped or re-run does not shadow the run the
notification referred to.  When multiple failed runs share the branch,
prefers the run whose `name' matches the workflow parsed from the title.
Falls back to the best-effort URL returned by `gh-notifications--ci-html-url'
when the API call fails."
  (let* ((id         (gh-notifications-notification-id n))
         (title      (or (gh-notifications-notification-subject-title n) ""))
         (branch     (gh-notifications--ci-branch-from-title title))
         (workflow   (gh-notifications--ci-workflow-from-title title))
         (conclusion (gh-notifications--ci-conclusion-from-title title))
         (repo       (gh-notifications-notification-repo-full-name n))
         (params     (append `((branch   . ,branch)
                               (per_page . "10"))
                             (unless (equal conclusion "unknown")
                               `((status . ,conclusion))))))
    (gh-notifications--without-keepalive
      (ghub-get (format "/repos/%s/actions/runs" repo)
                params
                :host gh-notifications-host
                :auth 'none
                :headers (gh-notifications--auth-headers)
                :callback
                (lambda (data _headers _status _req)
                  (let* ((runs    (append (alist-get 'workflow_runs data) nil))
                         (matched (and workflow
                                       (seq-find
                                        (lambda (r)
                                          (equal (alist-get 'name r) workflow))
                                        runs)))
                         (run     (or matched (car runs)))
                         (url     (and run (alist-get 'html_url run))))
                    (when url
                      (let* ((existing (gethash id gh-notifications--augmentations))
                             (merged   (plist-put (copy-sequence existing)
                                                  :ci-run-url url))
                             (merged   (plist-put merged
                                                  :ci-run-conclusion conclusion))
                             (merged   (plist-put merged
                                                  :ci-run-workflow workflow)))
                        (puthash id merged gh-notifications--augmentations))))
                  (gh-notifications--open-notification n))
                :errorback
                (lambda (err _headers _status _req)
                  (let ((inhibit-message t))
                    (message "gh-notifications: run lookup failed (%s); opening fallback" err))
                  (gh-notifications--open-notification n))))))

(defun gh-notifications-toggle-mark ()
  "Toggle the batch mark on the notification at point and advance to the next line."
  (interactive)
  (when-let* ((n  (gh-notifications--notification-at-point))
              (id (gh-notifications-notification-id n)))
    (if (member id gh-notifications--marked)
        (setq gh-notifications--marked (delete id gh-notifications--marked))
      (push id gh-notifications--marked))
    (gh-notifications--render)
    (forward-line 1)))

(defun gh-notifications-toggle-keep ()
  "Toggle local keep for the notification at point.
Kept notifications survive reconciliation pruning even when missing remotely."
  (interactive)
  (when-let* ((n (gh-notifications--notification-at-point))
              (id (gh-notifications-notification-id n)))
    (if (member id gh-notifications--kept-ids)
        (setq gh-notifications--kept-ids
              (delete id gh-notifications--kept-ids))
      (push id gh-notifications--kept-ids))
    (gh-notifications--render)
    (message "gh-notifications: %s local keep"
             (if (member id gh-notifications--kept-ids)
                 "enabled"
               "disabled"))))

(defun gh-notifications-unmark-all ()
  "Remove all batch marks."
  (interactive)
  (setq gh-notifications--marked nil)
  (gh-notifications--render))

(defun gh-notifications-mark-all ()
  "Mark all currently visible (filtered) notifications."
  (interactive)
  (setq gh-notifications--marked
        (mapcar (lambda (p)
                  (gh-notifications-notification-id (cdr p)))
                (gh-notifications--filtered-notifications)))
  (gh-notifications--render))

(defun gh-notifications--notifications-in-section ()
  "Return all notification structs in the repo section containing point."
  (when-let* ((section (magit-current-section))
              (repo-section
               (if (eq (oref section type) 'gh-notifications-repo)
                   section
                 (let ((parent (oref section parent)))
                   (when (and parent
                              (eq (oref parent type) 'gh-notifications-repo))
                     parent)))))
    (let ((start  (oref repo-section content))
          (end    (oref repo-section end))
          notifs)
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (when-let* ((n (get-text-property (point) 'gh-notification)))
            (push n notifs))
          (forward-line 1)))
      notifs)))

(defun gh-notifications--notifications-in-region (beg end)
  "Return all notification structs on lines that overlap BEG to END."
  (let (notifs)
    (save-excursion
      (goto-char beg)
      (beginning-of-line)
      (while (< (point) end)
        (when-let* ((n (get-text-property (point) 'gh-notification)))
          (push n notifs))
        (forward-line 1)))
    (delete-dups notifs)))

(defun gh-notifications-section-or-region-done ()
  "Mark all notifications in the active region or repo section at point as done.
In the inbox view this deletes the threads on GitHub with bounded concurrency.
In the saved view this removes the notifications from the persisted store.
Pushes the batch as a single action-ring entry so Z restores all at once."
  (interactive)
  (when (eq gh-notifications--view 'mine)
    (user-error "Mark done is unavailable in My PRs view"))
  (let* ((notifs   (if (use-region-p)
                       (gh-notifications--notifications-in-region
                        (region-beginning) (region-end))
                     (gh-notifications--notifications-in-section)))
         (count    (length notifs))
         (done     0)
         (inflight 0)
         (queue    (copy-sequence notifs)))
    (deactivate-mark)
    (cond
     ((null notifs)
      (user-error "No notifications here"))
     ((eq gh-notifications--view 'saved)
      (gh-notifications--saved-remove notifs)
      (message "gh-notifications: removed %d from saved (Z to undo)" count))
     (t
      (gh-notifications--push-action "mark-done" notifs 'inbox)
      (cl-labels
          ((fire-next ()
             (while (and queue
                         (< inflight gh-notifications-augment-concurrency))
               (let ((n (pop queue)))
                 (cl-incf inflight)
                 (gh-notifications--api-mark-done
                  (gh-notifications-notification-id n)
                  (lambda ()
                    (cl-decf inflight)
                    (cl-incf done)
                    (fire-next)
                    (when (= done count)
                      (gh-notifications--render)
                      (message "gh-notifications: marked %d done (Z to undo locally)"
                               count))))))))
        (fire-next))))))

(defun gh-notifications-execute-marked ()
  "Open the batch dispatch transient for the currently marked notifications."
  (interactive)
  (if (null gh-notifications--marked)
      (user-error "No notifications marked; use m to mark notifications")
    (gh-notifications-batch-dispatch)))

;;; Batch commands

(defun gh-notifications--batch-do (action label)
  "Apply ACTION to each marked notification ID with limited concurrency.
At most `gh-notifications-augment-concurrency' requests run simultaneously,
preventing the url connection pool from being overwhelmed.
LABEL is used in the completion message.
The entire batch is pushed as a single action-ring entry."
  (let* ((ids      (copy-sequence gh-notifications--marked))
         (total    (length ids))
         (done     0)
         (inflight 0)
         (queue    (copy-sequence ids))
         (notifs   (delq nil (mapcar (lambda (id)
                                       (alist-get id gh-notifications--notifications
                                                  nil nil #'equal))
                                     ids))))
    (when notifs
      (gh-notifications--push-action label notifs))
    (cl-labels
        ((fire-next ()
           (while (and queue
                       (< inflight gh-notifications-augment-concurrency))
             (let ((id (pop queue)))
               (cl-incf inflight)
               (funcall action id
                        (lambda ()
                          (cl-decf inflight)
                          (cl-incf done)
                          (fire-next)
                          (when (= done total)
                            (setq gh-notifications--marked nil)
                            (gh-notifications--render)
                            (message "gh-notifications: %s %d notification(s) (Z to undo locally)"
                                     label total))))))))
      (fire-next))))

(defun gh-notifications-batch-mark-done ()
  "Mark all marked notifications as done.
In the saved view this removes the marked notifications from the persisted
store instead of calling the GitHub API."
  (interactive)
  (cond
   ((null gh-notifications--marked)
    (user-error "No notifications marked"))
   ((eq gh-notifications--view 'mine)
    (user-error "Mark done is unavailable in My PRs view"))
   ((eq gh-notifications--view 'saved)
    (let ((notifs (delq nil
                        (mapcar (lambda (id)
                                  (alist-get id gh-notifications--saved
                                             nil nil #'equal))
                                gh-notifications--marked))))
      (gh-notifications--saved-remove notifs)
      (setq gh-notifications--marked nil)
      (message "gh-notifications: removed %d from saved (Z to undo)"
               (length notifs))))
   (t
    (gh-notifications--batch-do #'gh-notifications--api-mark-done "marked done"))))

(defun gh-notifications-batch-mark-read ()
  "Mark all marked notifications as read."
  (interactive)
  (cond
   ((null gh-notifications--marked)
    (user-error "No notifications marked"))
   ((eq gh-notifications--view 'mine)
    (user-error "Mark read is unavailable in My PRs view"))
   (t
    (gh-notifications--batch-do #'gh-notifications--api-mark-read "marked read"))))

(defun gh-notifications-batch-unsubscribe ()
  "Unsubscribe from all marked notifications."
  (interactive)
  (cond
   ((null gh-notifications--marked)
    (user-error "No notifications marked"))
   ((eq gh-notifications--view 'mine)
    (user-error "Unsubscribe is unavailable in My PRs view"))
   (t
    (gh-notifications--batch-do
     #'gh-notifications--api-unsubscribe "unsubscribed from"))))

;;; Saved for later

(defun gh-notifications-save-for-later ()
  "Copy the notification at point into the saved-for-later store.
When already saved, this is a no-op.  The store is persisted immediately.
Only meaningful in the inbox view."
  (interactive)
  (when (eq gh-notifications--view 'saved)
    (user-error "Already in the saved view"))
  (gh-notifications--saved-ensure-loaded)
  (when-let* ((n (gh-notifications--notification-at-point)))
    (let ((id (gh-notifications-notification-id n)))
      (if (alist-get id gh-notifications--saved nil nil #'equal)
          (message "gh-notifications: already saved")
        (let ((copy (copy-gh-notifications-notification n)))
          (setf (gh-notifications-notification-local-saved copy) t)
          (push (cons id copy) gh-notifications--saved))
        (gh-notifications--saved-persist)
        (gh-notifications--render)
        (message "gh-notifications: saved for later (L to view)")))))

(defun gh-notifications--saved-remove (notifs)
  "Remove NOTIFS from the saved store, persist, push undo entry, and re-render."
  (when notifs
    (gh-notifications--push-action "unsave" notifs 'saved)
    (dolist (n notifs)
      (setq gh-notifications--saved
            (assoc-delete-all (gh-notifications-notification-id n)
                              gh-notifications--saved #'equal)))
    (gh-notifications--saved-persist)
    (gh-notifications--render)))

(defun gh-notifications-saved-remove-at-point ()
  "Remove the notification at point from the saved store."
  (interactive)
  (when-let* ((n (gh-notifications--notification-at-point)))
    (gh-notifications--saved-remove (list n))
    (message "gh-notifications: removed from saved (Z to undo)")))

(defun gh-notifications-show-saved ()
  "Open the saved-for-later view."
  (interactive)
  (gh-notifications--saved-ensure-loaded)
  (let ((buf (gh-notifications--buffer 'saved)))
    (pop-to-buffer buf)
    (gh-notifications--render)))

(defun gh-notifications-show-my-prs ()
  "Open the authored pull requests view.
This view is backed by GitHub Search API results instead of notifications."
  (interactive)
  (let ((buf (gh-notifications--buffer 'mine)))
    (pop-to-buffer buf)
    (if gh-notifications--mine
        (gh-notifications--render)
      (gh-notifications-refresh))))

;;; Filter commands

(defun gh-notifications-set-filter-text (text)
  "Set the text filter to TEXT and refresh the buffer."
  (interactive "sFilter text (empty to clear): ")
  (setq gh-notifications--filter-text (or text ""))
  (gh-notifications--render))

(defun gh-notifications-toggle-filter-unread ()
  "Toggle the unread-only filter."
  (interactive)
  (setq gh-notifications--filter-unread-only
        (not gh-notifications--filter-unread-only))
  (gh-notifications--render))

(defun gh-notifications-set-filter-repos (repos)
  "Restrict the view to REPOS, a list of owner/repo strings.
Selecting nothing clears the repo filter."
  (interactive
   (list
    (let* ((all (delete-dups
                 (mapcar (lambda (p)
                           (gh-notifications-notification-repo-full-name (cdr p)))
                         gh-notifications--notifications)))
           (chosen (completing-read-multiple "Filter repos (empty for all): " all)))
      (if (or (null chosen) (equal chosen '(""))) nil chosen))))
  (setq gh-notifications--filter-repos repos)
  (gh-notifications--render))

(defun gh-notifications-set-filter-types (types)
  "Restrict the view to subject TYPES, a list of type name strings.
Selecting nothing clears the type filter."
  (interactive
   (list
    (let* ((all    '("PullRequest" "Issue" "CheckSuite" "Release" "Discussion"))
           (chosen (completing-read-multiple "Filter types (empty for all): " all)))
      (if (or (null chosen) (equal chosen '(""))) nil chosen))))
  (setq gh-notifications--filter-types types)
  (gh-notifications--render))

(defun gh-notifications-clear-filters ()
  "Clear all active filters and refresh the buffer."
  (interactive)
  (setq gh-notifications--filter-text                     ""
        gh-notifications--filter-unread-only               nil
        gh-notifications--filter-types                     nil
        gh-notifications--filter-repos                     nil
        gh-notifications--filter-ci-conclusions            nil
        gh-notifications--filter-hide-ci                   nil
        gh-notifications--filter-hide-automation-and-ci    nil
        gh-notifications--filter-hide-renovate             nil
        gh-notifications--filter-users                     nil)
  (gh-notifications--render))

(defun gh-notifications-toggle-filter-hide-renovate ()
  "Toggle visibility of Renovate pull request notifications.
When enabled, hides PullRequest notifications whose augmented author login
appears in `gh-notifications-renovate-logins'."
  (interactive)
  (setq gh-notifications--filter-hide-renovate
        (not gh-notifications--filter-hide-renovate))
  (gh-notifications--render))

(defun gh-notifications-toggle-filter-hide-automation-and-ci ()
  "Toggle visibility of automation and CI notifications.
When enabled, hides all CheckSuite notifications and PullRequest
notifications that match any rule in `gh-notifications-sweep-rules'."
  (interactive)
  (setq gh-notifications--filter-hide-automation-and-ci
        (not gh-notifications--filter-hide-automation-and-ci))
  (gh-notifications--render))

;;; CI filter commands

(defun gh-notifications-toggle-hide-ci ()
  "Toggle visibility of CI (CheckSuite) notifications."
  (interactive)
  (setq gh-notifications--filter-hide-ci
        (not gh-notifications--filter-hide-ci))
  (gh-notifications--render))

(defconst gh-notifications--ci-conclusions
  '("success" "failure" "neutral" "cancelled" "skipped" "timed_out" "action_required" "unknown")
  "All possible CI conclusion strings.")

(defun gh-notifications-filter-ci-failures ()
  "Show only CI notifications with a failure-class conclusion.
Covers failure, timed_out, and action_required."
  (interactive)
  (setq gh-notifications--filter-ci-conclusions
        '("failure" "timed_out" "action_required"))
  (gh-notifications--render))

(defun gh-notifications-set-filter-ci-conclusions (conclusions)
  "Restrict visible CI notifications to those with one of CONCLUSIONS.
Selecting nothing clears the CI conclusion filter."
  (interactive
   (list
    (let ((chosen (completing-read-multiple
                   "CI conclusions (empty for all): "
                   gh-notifications--ci-conclusions)))
      (if (or (null chosen) (equal chosen '(""))) nil chosen))))
  (setq gh-notifications--filter-ci-conclusions conclusions)
  (gh-notifications--render))

(defun gh-notifications-clear-filter-ci ()
  "Clear the CI conclusion filter."
  (interactive)
  (setq gh-notifications--filter-ci-conclusions nil)
  (gh-notifications--render))

(defun gh-notifications-sweep-ci-success ()
  "Mark done all visible CI notifications with a non-failure conclusion.
Covers: success, skipped, neutral, cancelled.
Prompts for confirmation before making any API calls."
  (interactive)
  (let* ((sweepable '("success" "skipped" "neutral" "cancelled"))
         (targets
          (seq-filter
           (lambda (pair)
             (let* ((n   (cdr pair))
                    (aug (gethash (gh-notifications-notification-id n)
                                  gh-notifications--augmentations)))
               (and (string= (gh-notifications-notification-subject-type n)
                             "CheckSuite")
                    (member (plist-get aug :ci-conclusion) sweepable))))
           (gh-notifications--filtered-notifications))))
    (if (null targets)
        (message "gh-notifications: no sweepable CI notifications found")
      (when (yes-or-no-p
             (format "Mark %d success/skipped/neutral/cancelled CI notification(s) done? "
                     (length targets)))
        (setq gh-notifications--marked
              (mapcar (lambda (p)
                        (gh-notifications-notification-id (cdr p)))
                      targets))
        (gh-notifications--batch-do #'gh-notifications--api-mark-done "swept")))))

;;; Rule-based automated PR sweeps

(defconst gh-notifications--sweep-inactive-states '("merged" "closed")
  "PR states considered inactive for rule-based sweeps.
Open and draft PRs are left alone because they may still need review.")

(defconst gh-notifications--sweep-open-states '("open" "draft")
  "PR states considered stuck for automated sync cleanup sweeps.")

(defvar-local gh-notifications--active-sweep-rule nil
  "Name of the sweep rule most recently applied in this buffer.
Used by `gh-notifications-sweep-inactive-rule' to skip re-prompting.")

(defun gh-notifications--sweep-rule-by-name (name)
  "Return the sweep rule entry named NAME, or nil."
  (assoc name gh-notifications-sweep-rules))

(defun gh-notifications--sweep-select-rule (prompt)
  "Prompt with PROMPT for a sweep rule and return its entry."
  (unless gh-notifications-sweep-rules
    (user-error "`gh-notifications-sweep-rules' is empty"))
  (let ((name (completing-read
               prompt
               (mapcar #'car gh-notifications-sweep-rules)
               nil t nil nil
               gh-notifications--active-sweep-rule)))
    (or (gh-notifications--sweep-rule-by-name name)
        (user-error "Unknown sweep rule %S" name))))

(defun gh-notifications--sweep-rule-repo-suffix (rule)
  "Return the :repo suffix stored in RULE."
  (plist-get (cdr rule) :repo))

(defun gh-notifications--sweep-rule-prefixes (rule)
  "Return the list of :prefixes stored in RULE."
  (plist-get (cdr rule) :prefixes))

(defun gh-notifications--sweep-rule-repos (rule)
  "Return the currently known repos whose full name ends with RULE's suffix."
  (let ((suffix (gh-notifications--sweep-rule-repo-suffix rule)))
    (delete-dups
     (delq nil
           (mapcar (lambda (pair)
                     (let ((repo (gh-notifications-notification-repo-full-name
                                  (cdr pair))))
                       (when (and repo (string-suffix-p suffix repo))
                         repo)))
                   gh-notifications--notifications)))))

(defun gh-notifications--sweep-rule-title-match-p (rule n)
  "Return non-nil when N's title starts with any prefix from RULE."
  (let ((title (or (gh-notifications-notification-subject-title n) "")))
    (seq-some (lambda (prefix)
                (and prefix
                     (>= (length title) (length prefix))
                     (string-equal-ignore-case
                      (substring title 0 (length prefix)) prefix)))
              (gh-notifications--sweep-rule-prefixes rule))))

(defun gh-notifications--sweep-rule-repo-match-p (rule n)
  "Return non-nil when N's repo full name ends with RULE's suffix."
  (let ((suffix (gh-notifications--sweep-rule-repo-suffix rule))
        (repo   (gh-notifications-notification-repo-full-name n)))
    (and repo suffix (string-suffix-p suffix repo))))

(defun gh-notifications-filter-sweep-rule (rule)
  "Narrow the view to PullRequest notifications matching sweep RULE.
Interactively prompts for the rule name from `gh-notifications-sweep-rules'.
Sets the repo filter to the rule's matching repos, restricts the type filter
to PullRequest, and clears the text filter (so multiple prefixes can match).
Remembers the selected rule so `gh-notifications-sweep-inactive-rule' can
re-use it."
  (interactive
   (list (gh-notifications--sweep-select-rule "Sweep rule: ")))
  (let ((repos (gh-notifications--sweep-rule-repos rule))
        (name  (car rule)))
    (unless repos
      (user-error "No repos matching %S found in current notifications"
                  (gh-notifications--sweep-rule-repo-suffix rule)))
    (setq gh-notifications--filter-repos repos
          gh-notifications--filter-types '("PullRequest")
          gh-notifications--filter-text  ""
          gh-notifications--active-sweep-rule name))
  (gh-notifications--render))

(defun gh-notifications-sweep-inactive-rule (rule)
  "Mark done every visible inactive PR matching sweep RULE.
A notification is swept when it is a PullRequest whose repo full name ends
with RULE's :repo suffix, whose title starts with one of RULE's :prefixes,
and whose augmentation :pr-state is merged or closed.  Open and draft PRs
are preserved.
Interactively re-uses the last rule applied via
`gh-notifications-filter-sweep-rule' in this buffer.  Pass a prefix argument
to choose a different rule.
Only augmented notifications are eligible; run after augmentation completes.
Prompts for confirmation before making any API calls."
  (interactive
   (list (if (and (not current-prefix-arg)
                  gh-notifications--active-sweep-rule
                  (gh-notifications--sweep-rule-by-name
                   gh-notifications--active-sweep-rule))
             (gh-notifications--sweep-rule-by-name
              gh-notifications--active-sweep-rule)
           (gh-notifications--sweep-select-rule "Sweep rule: "))))
  (let* ((name (car rule))
         (candidates
          (seq-filter
           (lambda (pair)
             (let ((n (cdr pair)))
               (and (string= (gh-notifications-notification-subject-type n)
                             "PullRequest")
                    (gh-notifications--sweep-rule-repo-match-p rule n)
                    (gh-notifications--sweep-rule-title-match-p rule n))))
           (gh-notifications--filtered-notifications)))
         (targets
          (seq-filter
           (lambda (pair)
             (let* ((n   (cdr pair))
                    (aug (gethash (gh-notifications-notification-id n)
                                  gh-notifications--augmentations)))
               (member (plist-get aug :pr-state)
                       gh-notifications--sweep-inactive-states)))
           candidates))
         (unaugmented
          (seq-count
           (lambda (pair)
             (let ((aug (gethash (gh-notifications-notification-id (cdr pair))
                                 gh-notifications--augmentations)))
               (not (plist-get aug :fetched))))
           candidates))
         (merged (seq-count
                  (lambda (pair)
                    (let ((aug (gethash (gh-notifications-notification-id (cdr pair))
                                        gh-notifications--augmentations)))
                      (string= (plist-get aug :pr-state) "merged")))
                  targets))
         (closed (- (length targets) merged)))
    (cond
     ((and (null targets) (> unaugmented 0))
      (message "gh-notifications: %d matching PR(s) not yet augmented; wait and retry"
               unaugmented))
     ((null targets)
      (message "gh-notifications: no inactive %s PRs to sweep" name))
     (t
      (when (yes-or-no-p
             (format "Mark %d inactive %s PR(s) done (%d merged, %d closed)%s? "
                     (length targets) name merged closed
                     (if (> unaugmented 0)
                         (format "; %d unaugmented skipped" unaugmented)
                       "")))
        (setq gh-notifications--marked
              (mapcar (lambda (p)
                        (gh-notifications-notification-id (cdr p)))
                      targets))
        (gh-notifications--batch-do #'gh-notifications--api-mark-done "swept"))))))

(defun gh-notifications-sweep-close-open-rule (rule)
  "Close and clean up visible open PRs matching sweep RULE.
A notification is targeted when it is a PullRequest whose repo full name ends
with RULE's :repo suffix, whose title starts with one of RULE's :prefixes,
and whose augmentation :pr-state is open or draft.
The command closes each PR, deletes the PR head branch, then marks the
notification done.
Interactively re-uses the last rule applied via
`gh-notifications-filter-sweep-rule' in this buffer.  Pass a prefix argument
to choose a different rule.
Only augmented notifications are eligible; run after augmentation completes.
Prompts for confirmation before making any API calls."
  (interactive
   (list (if (and (not current-prefix-arg)
                  gh-notifications--active-sweep-rule
                  (gh-notifications--sweep-rule-by-name
                   gh-notifications--active-sweep-rule))
             (gh-notifications--sweep-rule-by-name
              gh-notifications--active-sweep-rule)
           (gh-notifications--sweep-select-rule "Sweep rule: "))))
  (let* ((name (car rule))
         (candidates
          (seq-filter
           (lambda (pair)
             (let ((n (cdr pair)))
               (and (string= (gh-notifications-notification-subject-type n)
                             "PullRequest")
                    (gh-notifications--sweep-rule-repo-match-p rule n)
                    (gh-notifications--sweep-rule-title-match-p rule n))))
           (gh-notifications--filtered-notifications)))
         (targets
          (seq-filter
           (lambda (pair)
             (let* ((n   (cdr pair))
                    (aug (gethash (gh-notifications-notification-id n)
                                  gh-notifications--augmentations)))
               (member (plist-get aug :pr-state)
                       gh-notifications--sweep-open-states)))
           candidates))
         (unaugmented
          (seq-count
           (lambda (pair)
             (let ((aug (gethash (gh-notifications-notification-id (cdr pair))
                                 gh-notifications--augmentations)))
               (not (plist-get aug :fetched))))
           candidates))
         (open (seq-count
                (lambda (pair)
                  (let ((aug (gethash (gh-notifications-notification-id (cdr pair))
                                      gh-notifications--augmentations)))
                    (string= (plist-get aug :pr-state) "open")))
                targets))
         (draft (- (length targets) open)))
    (cond
     ((and (null targets) (> unaugmented 0))
      (message "gh-notifications: %d matching PR(s) not yet augmented; wait and retry"
               unaugmented))
     ((null targets)
      (message "gh-notifications: no open %s PRs to close" name))
     (t
      (when (yes-or-no-p
             (format "Close %d open %s PR(s), delete branches, and mark done (%d open, %d draft)%s? "
                     (length targets) name open draft
                     (if (> unaugmented 0)
                         (format "; %d unaugmented skipped" unaugmented)
                       "")))
        (setq gh-notifications--marked
              (mapcar (lambda (p)
                        (gh-notifications-notification-id (cdr p)))
                      targets))
        (gh-notifications--batch-do
         #'gh-notifications--api-close-pr-and-delete-branch
         "closed and cleaned up"))))))

(defun gh-notifications-filter-deployment-tools-cicd ()
  "Deprecated.  Applies the `deployment-tools cicd' sweep rule.
Use `gh-notifications-filter-sweep-rule' instead."
  (interactive)
  (gh-notifications-filter-sweep-rule
   (or (gh-notifications--sweep-rule-by-name "deployment-tools cicd")
       (user-error "Rule 'deployment-tools cicd' not defined"))))

(defun gh-notifications-sweep-inactive-cicd ()
  "Deprecated.  Sweeps the `deployment-tools cicd' rule.
Use `gh-notifications-sweep-inactive-rule' instead."
  (interactive)
  (gh-notifications-sweep-inactive-rule
   (or (gh-notifications--sweep-rule-by-name "deployment-tools cicd")
       (user-error "Rule 'deployment-tools cicd' not defined"))))

(defalias 'gh-notifications-sweep-merged-cicd #'gh-notifications-sweep-inactive-cicd
  "Deprecated alias for `gh-notifications-sweep-inactive-cicd'.")

;;; User filter commands

(defun gh-notifications-set-filter-users (users)
  "Restrict visible PR/Issue notifications to those involving USERS.
USERS is a list of GitHub login strings.  Selecting nothing clears the filter.
Augmentation fetches begin automatically for any unaugmented visible notifications."
  (interactive
   (list
    (let* ((pinned (or gh-notifications-pinned-users nil))
           (all    (delete-dups
                    (append pinned
                            (delq nil
                                  (mapcar (lambda (pair)
                                            (plist-get
                                             (gethash (gh-notifications-notification-id (cdr pair))
                                                      gh-notifications--augmentations)
                                             :author))
                                          gh-notifications--notifications)))))
           (chosen (completing-read-multiple
                    "Filter users (empty for all): " all)))
      (if (or (null chosen) (equal chosen '(""))) nil chosen))))
  (setq gh-notifications--filter-users users)
  (gh-notifications--render))

(defun gh-notifications-clear-filter-users ()
  "Clear the user filter."
  (interactive)
  (setq gh-notifications--filter-users nil)
  (gh-notifications--render))

(defun gh-notifications--toggle-user-filter (login)
  "Toggle LOGIN in `gh-notifications--filter-users' and refresh."
  (setq gh-notifications--filter-users
        (if (member login gh-notifications--filter-users)
            (delete login gh-notifications--filter-users)
          (cons login gh-notifications--filter-users)))
  (when gh-notifications--filter-users
    (dolist (pair gh-notifications--notifications)
      (gh-notifications--queue-augmentation (cdr pair)))
    (gh-notifications--augment-run-queue))
  (gh-notifications--render))

;;; Detail view

(defconst gh-notifications--detail-buffer-name "*GitHub Notification*"
  "Name of the notification detail buffer.")

(defun gh-notifications--detail-field (label value &optional face)
  "Insert a labelled field line with LABEL and VALUE into the current buffer.
FACE, when non-nil, is applied to VALUE."
  (insert (propertize (format "%-18s" label) 'font-lock-face 'magit-section-secondary-heading))
  (insert (if (and face value)
              (propertize value 'font-lock-face face)
            (or value "")))
  (insert "\n"))

(defun gh-notifications--detail-field-list (label items &optional face)
  "Insert a labelled multi-value field for ITEMS under LABEL.
Each item in ITEMS is propertized with FACE when provided.
Renders nothing when ITEMS is nil or empty."
  (when items
    (insert (propertize (format "%-18s" label) 'font-lock-face 'magit-section-secondary-heading))
    (insert (mapconcat (lambda (item)
                         (if face (propertize item 'font-lock-face face) item))
                       items
                       (propertize "  " 'font-lock-face 'magit-dimmed)))
    (insert "\n")))

(defun gh-notifications-show ()
  "Show all collected information for the notification at point in a detail buffer."
  (interactive)
  (let ((n (gh-notifications--notification-at-point)))
    (unless n
      (user-error "No notification at point"))
    (let* ((id         (gh-notifications-notification-id n))
           (aug        (gethash id gh-notifications--augmentations))
           (type       (gh-notifications-notification-subject-type n))
           (title      (gh-notifications-notification-subject-title n))
           (url        (gh-notifications--subject-html-url n))
           (api-url    (gh-notifications-notification-subject-url n))
           (repo       (gh-notifications-notification-repo-full-name n))
           (repo-url   (gh-notifications-notification-repo-html-url n))
           (reason     (gh-notifications-notification-reason n))
           (updated    (gh-notifications-notification-updated-at n))
           (unread     (gh-notifications-notification-unread n))
           (conclusion (plist-get aug :ci-conclusion))
           (author     (plist-get aug :author))
           (assignees  (plist-get aug :assignees))
           (reviewers  (plist-get aug :reviewers))
           (fetched    (plist-get aug :fetched))
           (buf        (get-buffer-create gh-notifications--detail-buffer-name)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (gh-notifications-detail-mode)
          (magit-insert-section (gh-notifications-detail)
            (magit-insert-section (gh-notifications-detail-subject)
              (magit-insert-heading
                (gh-notifications--type-indicator type)
                " "
                (propertize (or title "(no title)") 'font-lock-face
                            (if unread
                                'gh-notifications-unread
                              'gh-notifications-read)))
              (insert "\n")
              (gh-notifications--detail-field "Repo"     repo       'gh-notifications-repo)
              (gh-notifications--detail-field "Type"     type)
              (gh-notifications--detail-field "Reason"   reason     'gh-notifications-reason)
              (when-let* ((pr-state (plist-get aug :pr-state))
                          (face (pcase pr-state
                                  ("merged" 'gh-notifications-pr-merged)
                                  ("closed" 'gh-notifications-pr-closed)
                                  ("draft"  'gh-notifications-pr-draft)
                                  (_         nil))))
                (gh-notifications--detail-field "PR state" pr-state face))
              (gh-notifications--detail-field "Updated"  updated    'magit-dimmed)
              (gh-notifications--detail-field "Unread"   (if unread "yes" "no"))
              (gh-notifications--detail-field "Keep local" (if (member id gh-notifications--kept-ids) "yes" "no")
                                              'gh-notifications-keep)
              (gh-notifications--detail-field "Thread"   id         'magit-hash)
              (when url
                (gh-notifications--detail-field "URL" url 'magit-filename))
              (when (and api-url (not (equal api-url url)))
                (gh-notifications--detail-field "API URL" api-url 'magit-dimmed))
              (when repo-url
                (gh-notifications--detail-field "Repo URL" repo-url 'magit-dimmed))
              (insert "\n"))
            (when (or conclusion author assignees reviewers)
              (magit-insert-section (gh-notifications-detail-augmentation)
                (magit-insert-heading
                  (propertize "Augmentation" 'font-lock-face 'magit-section-heading))
                (insert "\n")
                (when conclusion
                  (let ((face (pcase conclusion
                                ("success"          'magit-signature-good)
                                ("failure"          'magit-signature-bad)
                                ("timed_out"        'magit-signature-bad)
                                ("action_required"  'magit-signature-bad)
                                ("cancelled"        'magit-dimmed)
                                ("skipped"          'magit-dimmed)
                                ("neutral"          'magit-dimmed)
                                (_                  'magit-dimmed))))
                    (gh-notifications--detail-field "CI conclusion" conclusion face)))
                (when author
                  (gh-notifications--detail-field "Author" author 'magit-log-author))
                (gh-notifications--detail-field-list "Assignees"  assignees  'magit-branch-local)
                (gh-notifications--detail-field-list "Reviewers"  reviewers  'magit-branch-remote)
                (insert "\n")))
            (when (and (member type '("PullRequest" "Issue"))
                       api-url
                       (not fetched))
              (magit-insert-section (gh-notifications-detail-note)
                (insert (propertize
                         "  Augmentation not yet fetched — activate a user filter or use\n  gh-notifications-fetch-augmentation to load author and reviewer data.\n"
                         'font-lock-face 'magit-dimmed)))))))
      (display-buffer buf
                      '((display-buffer-reuse-window
                         display-buffer-in-direction)
                        (direction . right)
                        (window-width . 0.4))))))

(defun gh-notifications-fetch-augmentation ()
  "Fetch REST augmentation for the notification at point and refresh the detail view."
  (interactive)
  (let ((n (if (eq major-mode 'gh-notifications-detail-mode)
               (with-current-buffer (get-buffer gh-notifications--buffer-name)
                 (gh-notifications--notification-at-point))
             (gh-notifications--notification-at-point))))
    (unless n
      (user-error "No notification to augment"))
    (let* ((id      (gh-notifications-notification-id n))
           (api-url (gh-notifications-notification-subject-url n)))
      (unless api-url
        (user-error "No API URL available for this notification type"))
      (message "gh-notifications: fetching details...")
      (gh-notifications--without-keepalive
        (ghub-get (replace-regexp-in-string
                   (rx "https://api.github.com") ""
                   api-url)
                  nil
                  :host gh-notifications-host
                  :auth 'none
                  :headers (gh-notifications--auth-headers)
                  :callback
                  (lambda (data _headers _status _req)
                    (let ((aug (list
                                :author    (alist-get 'login (alist-get 'user data))
                                :assignees (mapcar (lambda (a) (alist-get 'login a))
                                                   (alist-get 'assignees data))
                                :reviewers (mapcar (lambda (r) (alist-get 'login r))
                                                   (alist-get 'requested_reviewers data))
                                :pr-state  (gh-notifications--derive-pr-state data)
                                :fetched t)))
                      (puthash id aug gh-notifications--augmentations))
                    (message "gh-notifications: details fetched")
                    (gh-notifications-show))
                  :errorback
                  (lambda (err _headers _status _req)
                    (message "gh-notifications: augmentation error: %s" err)))))))

(define-derived-mode gh-notifications-detail-mode magit-section-mode "GH-Notif-Detail"
  "Major mode for the GitHub notification detail buffer."
  :group 'gh-notifications
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil))

(defvar gh-notifications-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `gh-notifications-detail-mode'.")

(define-key gh-notifications-detail-mode-map (kbd "q") #'quit-window)
(define-key gh-notifications-detail-mode-map (kbd "o") #'gh-notifications-open)
(define-key gh-notifications-detail-mode-map (kbd "f") #'gh-notifications-fetch-augmentation)

;;; Navigation

(defun gh-notifications-next-notification ()
  "Move point to the next notification line."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (get-text-property (line-beginning-position) 'gh-notification)))
      (forward-line 1))
    (when (eobp)
      (goto-char start)
      (user-error "No next notification"))))

(defun gh-notifications-previous-notification ()
  "Move point to the previous notification line."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (get-text-property (line-beginning-position) 'gh-notification)))
      (forward-line -1))
    (when (and (bobp)
               (not (get-text-property (line-beginning-position) 'gh-notification)))
      (goto-char start)
      (user-error "No previous notification"))))

(defun gh-notifications-jump-to-repo ()
  "Jump to a repository section chosen by completing read."
  (interactive)
  (let* ((groups  (gh-notifications--grouped-notifications))
         (repos   (mapcar #'car groups))
         (chosen  (completing-read "Jump to repo: " repos nil t)))
    (goto-char (point-min))
    (when (re-search-forward (concat "^" (regexp-quote chosen)) nil t)
      (beginning-of-line))))

;;; Section accessor

(defun gh-notifications--notification-at-point ()
  "Return the `gh-notifications-notification' on the current line, or nil."
  (get-text-property (line-beginning-position) 'gh-notification))

;;; Polling

(defun gh-notifications--start-poll-timer ()
  "Start the background polling timer, cancelling any existing one first."
  (gh-notifications--stop-poll-timer)
  (when (and gh-notifications-poll-interval
             (not gh-notifications--poll-paused))
    (setq gh-notifications--poll-timer
          (run-at-time gh-notifications-poll-interval
                       gh-notifications-poll-interval
                       #'gh-notifications--poll-tick))))

(defun gh-notifications--stop-poll-timer ()
  "Cancel the background polling timer if one is running."
  (when (timerp gh-notifications--poll-timer)
    (cancel-timer gh-notifications--poll-timer)
    (setq gh-notifications--poll-timer nil)))

(defun gh-notifications--poll-tick ()
  "Fetch notifications and re-render if the buffer is still live.
Background poll errors are logged silently to avoid interrupting the user."
  (when (and (not gh-notifications--poll-paused)
             (buffer-live-p (get-buffer gh-notifications--buffer-name)))
    (gh-notifications--fetch
     (lambda ()
       (when (buffer-live-p (get-buffer gh-notifications--buffer-name))
         (gh-notifications--render)))
     t)))

(defun gh-notifications-toggle-auto-refresh ()
  "Pause or resume automatic background polling."
  (interactive)
  (setq gh-notifications--poll-paused (not gh-notifications--poll-paused))
  (if gh-notifications--poll-paused
      (progn
        (gh-notifications--stop-poll-timer)
        (message "gh-notifications: auto-refresh paused"))
    (gh-notifications--start-poll-timer)
    (if gh-notifications-poll-interval
        (message "gh-notifications: auto-refresh resumed (%ss)"
                 gh-notifications-poll-interval)
      (message "gh-notifications: auto-refresh is disabled (poll interval is nil)"))))

;;; Per-pinned-user commands

(defun gh-notifications-filter-user-robbymilo ()
  "Toggle robbymilo in the user filter."
  (interactive)
  (gh-notifications--toggle-user-filter "robbymilo"))

(defun gh-notifications-filter-user-nate-walters-grafana ()
  "Toggle nate-walters-grafana in the user filter."
  (interactive)
  (gh-notifications--toggle-user-filter "nate-walters-grafana"))

(defun gh-notifications-filter-user-marc-nogue ()
  "Toggle marc-nogue in the user filter."
  (interactive)
  (gh-notifications--toggle-user-filter "marc-nogue"))

(defun gh-notifications-show-shortcuts ()
  "Show a compact keyboard and workflow guide."
  (interactive)
  (with-help-window "*GH Notifications shortcuts*"
    (princ "gh-notifications quick guide\n\n")
    (princ "Entry points\n")
    (princ "  ? or h   Open transient command menu\n")
    (princ "  H        Open this shortcuts guide\n")
    (princ "  O        Open My PRs view\n\n")
    (princ "Common actions\n")
    (princ "  RET or o Open notification\n")
    (princ "  d        Mark done\n")
    (princ "  k        Toggle local keep\n")
    (princ "  r        Mark read\n")
    (princ "  u        Unsubscribe\n")
    (princ "  m/M/U/x  Mark workflow\n\n")
    (princ "Filters\n")
    (princ "  / t / u / r / T / a / c  Text, unread, repo, type, human-only, clear\n")
    (princ "  C h / C f / C s / C /    CI filters and sweep\n")
    (princ "  @ 1 @ 2 @ 3 @ / @ c      User filters\n\n")
    (princ "Automated sweep workflow\n")
    (princ "  S f  Step 1: filter by sweep rule\n")
    (princ "  S s  Step 2: mark inactive PR notifications done\n")
    (princ "  S x  Step 3: close open PRs, delete branch, mark done\n\n")
    (princ "Use the transient menu labels for the same 3-step sweep hints.\n")))

;;; Transient menus

(transient-define-prefix gh-notifications-dispatch ()
  "Dispatch GitHub notification actions."
  ["Actions on notification at point"
   [("RET" "Show details"      gh-notifications-show)
    ("o"   "Open in browser"   gh-notifications-open)
    ("d"   "Mark done / unsave" gh-notifications-mark-done)
    ("D"   "Mark section/region done" gh-notifications-section-or-region-done)
    ("r"   "Mark read"         gh-notifications-mark-read)
    ("u"   "Unsubscribe"       gh-notifications-unsubscribe)
    ("s"   "Save for later"    gh-notifications-save-for-later)
    ("L"   "View saved"        gh-notifications-show-saved)
    ("O"   "View my pull requests" gh-notifications-show-my-prs)
    ("Z"   "Undo last action"  gh-notifications-undo)]
   [("m"   "Toggle mark"       gh-notifications-toggle-mark)
    ("M"   "Mark all visible"  gh-notifications-mark-all)
    ("U"   "Unmark all"        gh-notifications-unmark-all)
    ("k"   "Toggle local keep" gh-notifications-toggle-keep)
    ("x"   "Act on marked..."  gh-notifications-execute-marked)]]
  ["Filters"
   [("/ t" "By text"           gh-notifications-set-filter-text)
    ("/ u" "Unread only"       gh-notifications-toggle-filter-unread)
    ("/ r" "By repo"           gh-notifications-set-filter-repos)
    ("/ T" "By type"           gh-notifications-set-filter-types)
    ("/ a" "Human-only mode"   gh-notifications-toggle-filter-hide-automation-and-ci)
    ("/ R" "Hide Renovate PRs" gh-notifications-toggle-filter-hide-renovate)
    ("/ c" "Clear all"         gh-notifications-clear-filters)]
   [("C h" "CI: toggle hide"             gh-notifications-toggle-hide-ci)
    ("C f" "CI: failures only"          gh-notifications-filter-ci-failures)
    ("C s" "CI: sweep non-failures"     gh-notifications-sweep-ci-success)
    ("C /" "CI: by conclusion"          gh-notifications-set-filter-ci-conclusions)
    ("C c" "CI: clear"                  gh-notifications-clear-filter-ci)]
   [("@ 1" "@robbymilo"             gh-notifications-filter-user-robbymilo)
    ("@ 2" "@nate-walters-grafana"  gh-notifications-filter-user-nate-walters-grafana)
    ("@ 3" "@marc-nogue"            gh-notifications-filter-user-marc-nogue)
    ("@ /" "Users: by login"        gh-notifications-set-filter-users)
    ("@ c" "Users: clear"           gh-notifications-clear-filter-users)]
   [("S f" "Sweep 1/3: filter by rule"              gh-notifications-filter-sweep-rule)
    ("S s" "Sweep 2/3: mark inactive PRs done"      gh-notifications-sweep-inactive-rule)
    ("S x" "Sweep 3/3: close open PRs and prune"    gh-notifications-sweep-close-open-rule)]]
  ["Other"
   [("h"   "Help: show shortcuts and workflows" gh-notifications-show-shortcuts)
    ("n"   "Next notification"     gh-notifications-next-notification)
    ("p"   "Previous notification" gh-notifications-previous-notification)
    ("j"   "Jump to repo"          gh-notifications-jump-to-repo)
    ("g"   "Refresh"               gh-notifications-refresh)
    ("P"   "Pause/resume auto-refresh" gh-notifications-toggle-auto-refresh)
    ("q"   "Quit"                  quit-window)]])

(transient-define-prefix gh-notifications-batch-dispatch ()
  "Dispatch batch actions for all marked notifications."
  ["Batch actions"
   [("d" "Mark done"    gh-notifications-batch-mark-done)
    ("r" "Mark read"    gh-notifications-batch-mark-read)
    ("u" "Unsubscribe"  gh-notifications-batch-unsubscribe)]
   [("U" "Unmark all"   gh-notifications-unmark-all)]])

;;; Major mode

(defvar gh-notifications-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `gh-notifications-mode'.")

(define-key gh-notifications-mode-map (kbd "?")   #'gh-notifications-dispatch)
(define-key gh-notifications-mode-map (kbd "h")   #'gh-notifications-dispatch)
(define-key gh-notifications-mode-map (kbd "H")   #'gh-notifications-show-shortcuts)
(define-key gh-notifications-mode-map (kbd "Z")   #'gh-notifications-undo)
(define-key gh-notifications-mode-map (kbd "n")   #'gh-notifications-next-notification)
(define-key gh-notifications-mode-map (kbd "p")   #'gh-notifications-previous-notification)
(define-key gh-notifications-mode-map (kbd "j")   #'gh-notifications-jump-to-repo)
(define-key gh-notifications-mode-map (kbd "g")   #'gh-notifications-refresh)
(define-key gh-notifications-mode-map (kbd "P")   #'gh-notifications-toggle-auto-refresh)
(define-key gh-notifications-mode-map (kbd "RET") #'gh-notifications-show)
(define-key gh-notifications-mode-map (kbd "i")   #'gh-notifications-show)
(define-key gh-notifications-mode-map (kbd "o")   #'gh-notifications-open)
(define-key gh-notifications-mode-map (kbd "d")   #'gh-notifications-mark-done)
(define-key gh-notifications-mode-map (kbd "s")   #'gh-notifications-save-for-later)
(define-key gh-notifications-mode-map (kbd "L")   #'gh-notifications-show-saved)
(define-key gh-notifications-mode-map (kbd "O")   #'gh-notifications-show-my-prs)
(define-key gh-notifications-mode-map (kbd "D")   #'gh-notifications-section-or-region-done)
(define-key gh-notifications-mode-map (kbd "r")   #'gh-notifications-mark-read)
(define-key gh-notifications-mode-map (kbd "u")   #'gh-notifications-unsubscribe)
(define-key gh-notifications-mode-map (kbd "m")   #'gh-notifications-toggle-mark)
(define-key gh-notifications-mode-map (kbd "M")   #'gh-notifications-mark-all)
(define-key gh-notifications-mode-map (kbd "U")   #'gh-notifications-unmark-all)
(define-key gh-notifications-mode-map (kbd "k")   #'gh-notifications-toggle-keep)
(define-key gh-notifications-mode-map (kbd "x")   #'gh-notifications-execute-marked)
(define-key gh-notifications-mode-map (kbd "/ t") #'gh-notifications-set-filter-text)
(define-key gh-notifications-mode-map (kbd "/ u") #'gh-notifications-toggle-filter-unread)
(define-key gh-notifications-mode-map (kbd "/ r") #'gh-notifications-set-filter-repos)
(define-key gh-notifications-mode-map (kbd "/ T") #'gh-notifications-set-filter-types)
(define-key gh-notifications-mode-map (kbd "/ a") #'gh-notifications-toggle-filter-hide-automation-and-ci)
(define-key gh-notifications-mode-map (kbd "/ R") #'gh-notifications-toggle-filter-hide-renovate)
(define-key gh-notifications-mode-map (kbd "/ c") #'gh-notifications-clear-filters)
(define-key gh-notifications-mode-map (kbd "C h") #'gh-notifications-toggle-hide-ci)
(define-key gh-notifications-mode-map (kbd "C f") #'gh-notifications-filter-ci-failures)
(define-key gh-notifications-mode-map (kbd "C s") #'gh-notifications-sweep-ci-success)
(define-key gh-notifications-mode-map (kbd "C /") #'gh-notifications-set-filter-ci-conclusions)
(define-key gh-notifications-mode-map (kbd "C c") #'gh-notifications-clear-filter-ci)
(define-key gh-notifications-mode-map (kbd "@ 1") #'gh-notifications-filter-user-robbymilo)
(define-key gh-notifications-mode-map (kbd "@ 2") #'gh-notifications-filter-user-nate-walters-grafana)
(define-key gh-notifications-mode-map (kbd "@ 3") #'gh-notifications-filter-user-marc-nogue)
(define-key gh-notifications-mode-map (kbd "@ /") #'gh-notifications-set-filter-users)
(define-key gh-notifications-mode-map (kbd "@ c") #'gh-notifications-clear-filter-users)
(define-key gh-notifications-mode-map (kbd "S f") #'gh-notifications-filter-sweep-rule)
(define-key gh-notifications-mode-map (kbd "S s") #'gh-notifications-sweep-inactive-rule)
(define-key gh-notifications-mode-map (kbd "S x") #'gh-notifications-sweep-close-open-rule)
(define-key gh-notifications-mode-map (kbd "q")   #'quit-window)

(define-derived-mode gh-notifications-mode magit-section-mode "GH-Notif"
  "Major mode for browsing and acting on GitHub notifications."
  :group 'gh-notifications
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (gh-notifications-refresh)))
  (add-hook 'kill-buffer-hook #'gh-notifications--stop-poll-timer nil t))

;;; Entry point

;;;###autoload
(defun gh-notifications ()
  "Open the GitHub notifications manager."
  (interactive)
  (let ((buf (gh-notifications--buffer)))
    (pop-to-buffer buf)
    (gh-notifications--start-poll-timer)
    (if gh-notifications--notifications
        (gh-notifications--render)
      (gh-notifications-refresh))))

(provide 'gh-notifications)
;;; gh-notifications.el ends here
