(in-package #:sm-harness)

(defstruct (tool-policy (:constructor %make-tool-policy))
  (builtin-tools :none)
  (strict-mcp-p t))

(defun make-tool-policy (&key (builtin-tools :none)
                              (strict-mcp-p t))
  "Define the session-start availability boundary, not an approval policy."
  (%make-tool-policy
   :builtin-tools builtin-tools
   :strict-mcp-p strict-mcp-p))

(defun default-tool-policy ()
  "SDK-tools-only availability default: no builtins and no ambient MCP."
  (make-tool-policy
   :builtin-tools :none
   :strict-mcp-p t))
