(in-package #:sm-harness-web-ui)

(defun e2e-file-browser-scenario ()
  "#138: opens the file browser from the home screen (no session needed --
the tree isn't session-scoped), expands down to a real, stable file under
this repo's own docs -- rooted at / (the whole container filesystem), so
this expands one level further (into \"app\") than this feature's first,
narrower version did -- opens it in a new tab, and exercises both ways
of closing the drawer (the Close button and clicking the backdrop
outside it, #138 review answer 4)."
  (%e2e-object
   "name" "file-browser" "evidence_suffix" "opened-doc-in-new-tab"
   "steps"
   (list
    (%e2e-step "wait" "selector" "#browse-files" "state" "visible")
    (%e2e-step "click" "selector" "#browse-files")
    (%e2e-step "wait" "selector" ".file-browser-panel.open" "state" "visible")
    ;; The root listing (/) is lazy -- built the first time the panel
    ;; opens, not at page-load time -- so this also covers that it
    ;; actually ran.
    (%e2e-step "wait" "selector" ".file-tree-dir:has-text(\"app\")" "state" "visible")
    (%e2e-step "click" "selector" ".file-tree-dir:has-text(\"app\")")
    (%e2e-step "wait" "selector" ".file-tree-dir:has-text(\"harness\")" "state" "visible")
    (%e2e-step "click" "selector" ".file-tree-dir:has-text(\"harness\")")
    (%e2e-step "wait" "selector" ".file-tree-dir:has-text(\"docs\")" "state" "visible")
    (%e2e-step "click" "selector" ".file-tree-dir:has-text(\"docs\")")
    (%e2e-step "wait" "selector" ".file-tree-file:has-text(\"sm-harness-web-ui.md\")" "state" "visible")
    ;; The file row is a plain target="_blank" anchor -- clicking it opens
    ;; this repo's own real doc in a second tab, served by
    ;; %SERVE-FS-REQUEST-APP (ui/file-browser.lisp).
    (%e2e-step "click_new_tab"
               "selector" ".file-tree-file:has-text(\"sm-harness-web-ui.md\")"
               "url_pattern" "^/fs/app/harness/docs/sm-harness-web-ui\\.md$"
               "text_contains" "Container privileges and the live repo mount")
    ;; Close button.
    (%e2e-step "click" "selector" "#file-browser-close")
    (%e2e-step "wait" "selector" ".file-browser-panel.open" "state" "hidden")
    ;; Click-outside-to-close via the backdrop (#138 review answer 4).
    (%e2e-step "click" "selector" "#browse-files")
    (%e2e-step "wait" "selector" ".file-browser-panel.open" "state" "visible")
    (%e2e-step "click" "selector" "#file-browser-backdrop")
    (%e2e-step "wait" "selector" ".file-browser-panel.open" "state" "hidden"))))
