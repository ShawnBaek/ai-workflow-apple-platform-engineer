# Secrets, variables, and account boundaries

A secret authorizes or reveals sensitive state; a variable is non-secret
configuration. Masking is not an account guard, and a secret existing in GitHub
does not prove it belongs to the approved Apple/GitHub account.

## Classification

Secrets commonly include private keys, tokens, passwords, certificate exports,
webhook credentials, and signing material. Variables commonly include scheme,
workspace/project name, bundle ID, numeric app ID, intended Xcode build, runner
label, and deployment target. Treat identifiers as sensitive too when the
project's privacy policy requires it.

Use the narrowest repository/environment scope and least privilege. Protected
release environments should hold release credentials and require the project's
review gate. Never grant secrets to untrusted fork code.

## Safe setup

1. Verify the active personal/organization GitHub account and exact repository.
2. Compare the intended Apple team/account/profile with the private project
   policy before reading account data or storing credentials.
3. Show the variable/secret names, scope, required permissions, and rotation
   owner; get approval before creating or replacing them.
4. Pass multiline secret material from an approved file or standard input so the
   value is not in command history. Never print it for verification.
5. Verify only metadata (name/scope/update state) and a least-privilege dry/read
   operation. Do not echo the value.

Example shapes, with placeholders only:

```sh
gh secret set <SECRET_NAME> --env <protected-environment> < <approved-file>
gh variable set <VARIABLE_NAME> --env <environment> --body '<non-secret-value>'
```

Do not put real credentials, one-time codes, private-key bodies, or personal
account values in documentation, workflow YAML, PR bodies, logs, artifacts, or
RAG indexes.

## Workflow use

Reference secrets only in the step that requires them. Avoid job-wide environment
exposure. Keep write permissions off build/test jobs and isolate an external
mutation in a protected job. Redact commands and structured output before
uploading evidence.

A credential/scope/account mismatch stops the run. Do not switch profiles,
discover another account, broaden a token, or create replacement credentials to
make the workflow pass.

## Rotation and deletion

Rotation and deletion are external security mutations. Require exact secret,
scope, account, dependent workflows, rollback plan, and explicit approval. A new
value affects new jobs; preserve evidence about metadata and dependent workflow
validation, never the secret itself.

References:

- [GitHub Actions secrets](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions)
- [GitHub variables](https://docs.github.com/en/actions/learn-github-actions/variables)
- [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi)
