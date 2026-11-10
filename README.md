# gh-notifications.el

**Note:** this project was primarily AI-generated.

An Emacs GitHub notification manager built on `magit-section` and `transient`.
Notifications are grouped by repository in a collapsible section buffer.
All actions dispatch through a transient menu or direct key bindings.

## Installation

Using `straight.el` and `use-package`:

```emacs-lisp
(use-package gh-notifications
  :straight (:host github :repo "jdbaldry/gh-notifications.el")
  :commands gh-notifications)
```

## Authentication

The package calls `gh auth token` to obtain a GitHub API token.
No `auth-source` or `~/.authinfo` configuration is required.
If you can run `gh api user` in a terminal, the package will work without any additional setup.

If you are not already authenticated, run:

```
gh auth login
```

To force a fresh token lookup after re-authenticating, call `M-x gh-notifications-clear-token-cache`.

## Usage

Open the notification manager with:

```
M-x gh-notifications
```

Press `?` or `h` at any time to open the full transient dispatch menu.
Use `H` to open a compact shortcut and workflow guide.

## Deferred sync

Actions on notifications (done, read, unsubscribe, close PR) are not sent to GitHub immediately.
They are queued locally for instant UI feedback and flushed to GitHub on the next refresh (`g`).
You can sweep notifications away or mark a batch done, then sync it all later.

Queued actions are held in a SQLite database (`gh-notifications-db-file`) so they survive an Emacs restart.
The outbox view (`W`) lists everything queued to sync.
In the outbox, `d` cancels a queued action.
`Z` undoes the most recent queued batch before it is synced.

## Key bindings

| Key   | Action                                     |
| ----- | ------------------------------------------ |
| `?`   | Open transient dispatch menu               |
| `h`   | Open transient dispatch menu               |
| `H`   | Show shortcut and workflow guide           |
| `O`   | Open My PRs view (authored PRs)            |
| `W`   | Open outbox view (actions queued to sync)  |
| `RET` | Open notification in browser, queue read   |
| `o`   | Open notification in browser, queue read   |
| `d`   | Queue done (outbox: cancel queued action)  |
| `r`   | Queue read                                 |
| `u`   | Queue unsubscribe                          |
| `m`   | Toggle batch mark on notification at point |
| `M`   | Mark all visible notifications             |
| `U`   | Unmark all                                 |
| `x`   | Open batch dispatch for marked items       |
| `/ t` | Filter by text substring                   |
| `/ u` | Toggle unread-only filter                  |
| `/ r` | Filter by repository                       |
| `/ T` | Filter by subject type                     |
| `/ a` | Human-only mode (hide CI, sweep-rule and Renovate PRs) |
| `/ c` | Clear all filters                          |
| `S f` | Sweep step 1: filter by rule               |
| `S s` | Sweep step 2: mark inactive PRs done       |
| `S x` | Sweep step 3: close open PRs and prune     |
| `g`   | Sync queued actions and refresh            |
| `Z`   | Undo the most recent queued batch          |
| `q`   | Quit window                                |

Repo sections can be folded and unfolded with `TAB`, following the standard `magit-section` behavior.

## Customization

| Variable                               | Default                             | Description                                                                                    |
| -------------------------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------- |
| `gh-notifications-host`                | `"api.github.com"`                  | GitHub API host                                                                                |
| `gh-notifications-db-file`             | `~/.emacs.d/gh-notifications/pending.sqlite3` | SQLite database holding queued to-be-sent actions                                    |
| `gh-notifications-my-prs-query`        | `"is:pr is:open sort:updated-desc"` | Search query for My PRs view; `%s` is replaced with your login or `author:<login>` is appended |
| `gh-notifications-my-prs-max-pages`    | `10`                                | Max search pages for My PRs view (100 items per page)                                          |
| `gh-notifications-auto-mark-done-days` | `nil`                               | Auto-mark-done threshold in days; nil to disable                                               |
| `gh-notifications-older-than-days`     | `7`                                 | Notifications older than this are dimmed                                                       |

All faces are in the `gh-notifications` customization group and can be adjusted with `M-x customize-group RET gh-notifications RET`.
