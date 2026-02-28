# Cal Poly Jigsaw Puzzle Game

### Documentation
Documentation is hosted [here](16.145.72.178). Log in using Google account credentials.

### Server Stage Launch (EC2)
- Production server (port `8080`):
  - `./jigsaw_server.x86_64 --server --stage=prod`
- Beta server (port `8090`):
  - `./jigsaw_server.x86_64 --server --stage=beta`

If `--stage` is omitted, the app defaults to production.

### systemd ExecStart examples
- Prod service:
  - `ExecStart=/opt/jigsaw/jigsaw_server.x86_64 --server --stage=prod`
- Beta service:
  - `ExecStart=/opt/jigsaw/jigsaw_server.x86_64 --server --stage=beta`
