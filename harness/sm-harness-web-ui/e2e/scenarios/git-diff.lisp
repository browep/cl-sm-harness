(in-package #:sm-harness-web-ui)

(defun e2e-git-diff-scenario ()
  "#140: builds a small, deterministic scratch git repo on disk (via the
/e2e-setup-git-diff-fixture throwaway route, e2e/test-hooks.lisp -- see
its own comment for why a filesystem fixture needs that indirection
where a plain DOM assertion wouldn't), opens the file browser from the
home screen, walks the tree down to it, and exercises the Diff button's
whole path: changed-file list (a modified tracked file, an untracked
file) -> a single file's unified diff -> back to the file list -> back
to the tree -- plus the panel's .diff-open width class toggling with
that navigation."
  (%e2e-object
   "name" "git-diff" "evidence_suffix" "diff-viewed"
   "steps"
   (list
    (%e2e-step "open_tab" "path" "/e2e-setup-git-diff-fixture")
    (%e2e-step "wait" "selector" "#browse-files" "state" "visible")
    (%e2e-step "click" "selector" "#browse-files")
    (%e2e-step "wait" "selector" ".file-browser-panel.open" "state" "visible")
    (%e2e-step "wait" "selector" ".file-tree-dir:has-text(\"tmp\")" "state" "visible")
    (%e2e-step "click" "selector" ".file-tree-dir:has-text(\"tmp\")")
    (%e2e-step "wait" "selector" ".file-tree-dir:has-text(\"e2e-git-diff-fixture\")" "state" "visible")
    ;; The Diff button is a sibling of the expand/collapse row, not nested
    ;; inside it, so this never also triggers an expand of the fixture
    ;; directory itself.
    (%e2e-step "wait"
               "selector" ".file-tree-dir-row:has-text(\"e2e-git-diff-fixture\") .file-tree-diff-btn"
               "state" "visible")
    (%e2e-step "click"
               "selector" ".file-tree-dir-row:has-text(\"e2e-git-diff-fixture\") .file-tree-diff-btn")
    ;; Same drawer, second internal view: the tree hides, the diff view
    ;; shows, and the panel itself widens (.diff-open, app.css).
    (%e2e-step "wait" "selector" ".file-browser-panel.diff-open" "state" "visible")
    (%e2e-step "wait" "selector" "#file-tree" "state" "hidden")
    (%e2e-step "wait" "selector" ".git-diff-file-row:has-text(\"new-file.txt\")" "state" "visible")
    (%e2e-step "wait" "selector" ".git-diff-badge-untracked" "state" "visible")
    (%e2e-step "wait" "selector" ".git-diff-file-row:has-text(\"tracked.txt\")" "state" "visible")
    (%e2e-step "wait" "selector" ".git-diff-badge-modified" "state" "visible")
    ;; Into a single file's diff.
    (%e2e-step "click" "selector" ".git-diff-file-row:has-text(\"tracked.txt\")")
    (%e2e-step "wait" "selector" "#git-diff-body-wrap" "state" "visible")
    (%e2e-step "wait" "selector" ".diff-del:has-text(\"original line\")" "state" "visible")
    (%e2e-step "wait" "selector" ".diff-add:has-text(\"changed line\")" "state" "visible")
    ;; Back to the changed-file list, still within the diff view.
    (%e2e-step "click" "selector" "#git-diff-body-back")
    (%e2e-step "wait" "selector" "#git-diff-file-list" "state" "visible")
    (%e2e-step "wait" "selector" "#git-diff-body-wrap" "state" "hidden")
    ;; All the way back to the tree.
    (%e2e-step "click" "selector" "#git-diff-back")
    (%e2e-step "wait" "selector" "#file-tree" "state" "visible")
    (%e2e-step "wait" "selector" ".file-browser-panel.diff-open" "state" "hidden")
    (%e2e-step "click" "selector" "#file-browser-close")
    (%e2e-step "wait" "selector" ".file-browser-panel.open" "state" "hidden"))))
