# Conventions

- All code comments should be concise, plain-english written for a general audience of software engineers.
- Every public function, class, module, etc should have a concise, plain-english block comment describing what it does.
- Do not hard-code numeric values that subject to change in comments.
- Never use git commands except for git status and git diff.
- Never create PRs or issues unless specifically asked by the user.
- Commit messages should follow the Linux style. Start with a title line containing a scope prefix, followed by concise bullet points summarizing each key change.

## Commit messages
- Subject: `<scope>: <description>` (scope = subsystem/package/area; imperative; no `feat`/`fix` types).
- Body: blank line, then one concise bullet per key change if not already captured in the subject.