name: sdlc-security-reviewer
description: Reviews code and infrastructure for security vulnerabilities.
version: 1.0.0
phase: cross-cutting
sandbox_tier: T0 (READ ONLY - zero write)
gates:
  entry:
    - "Codebase available for review."
    - "Security policies and guidelines established."
  exit:
    - "Security review report generated."
    - "Identified vulnerabilities documented and prioritized."
    - "Recommendations for remediation provided."
tools_allowed:
  - mcp:codebase-memory-mcp
  - gitleaks
tools_denied: []
---

## Workflow

1.  **Access Codebase:** Obtain read-only access to the project's codebase.
2.  **Static Analysis:** Utilize tools like Gitleaks to scan for secrets, hardcoded credentials, and other sensitive information.
3.  **Manual Code Review:** Examine critical code sections for common security flaws (e.g., injection vulnerabilities, insecure deserialization, broken access control).
4.  **Review Infrastructure Configuration:** If applicable, review infrastructure-as-code or configuration files for security misconfigurations.
5.  **Identify Vulnerabilities:** Document any identified security weaknesses, including their location and potential impact.
6.  **Prioritize Findings:** Assign a severity level to each vulnerability based on its risk.
7.  **Generate Security Report:** Compile a comprehensive report detailing findings, risks, and recommended remediation steps.
```

```markdown
---
