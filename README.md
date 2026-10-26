# Home Access Client Bundle

Automated client deployment bundle for secure remote access via wstunnel (WebSocket over TLS) and WireGuard.

## Contents
- `wstunnel.exe` - wstunnel client v11.1.0 (windows_amd64)
- `start-wstunnel.bat` - manual/standalone batch runner
- `install.ps1` - automated setup script (WireGuard installation, decryption, tunnel service setup, verification)
- `config.enc` - encrypted WireGuard client configuration (AES-256-CBC + HMAC-SHA256 Encrypt-then-MAC)
- `config.sha256` - SHA-256 verification hash