# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: on this repository's
**Security** tab, choose **Report a vulnerability**. Don't open a public issue for
them. You'll get a reply within a week. Once a fix is released, the advisory is
published, crediting you unless you'd rather not be named.

Reports are welcome for anything that would let someone other than the developer
running VOFocus drive their Simulator or device, read what VOFocus records, or run
code through it. Examples: reaching the runner without its token, the token leaking,
or a scenario file running commands.

## Supported versions

Fixes go into the latest release only.

## How VOFocus is built to be safe

[docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md) describes what VOFocus runs, what it
can reach, what it records and where, and the permissions it needs.
