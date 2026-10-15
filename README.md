# Docker Runner Autoscaler

Run **GitHub Actions self-hosted Linux runners in Docker Desktop on Windows** and scale them automatically, from a small tray app.

- **Ephemeral runners**: every job gets a fresh container ([myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner))
- **Autoscaling**: always keeps one idle runner ready, adds more while all are busy, removes surplus after 2 minutes, and **never stops a busy runner**
- **Recommended maximum**, calculated from the CPU threads and memory of the Docker VM
- **Tray icon** with the number of runners (green = idle, orange = busy, red = all busy), click to open the live console
- **Manual mode**: set the runner count with the arrow keys
- **Auto-update** from GitHub Releases (SHA-256 verified), or manually: tray menu → *Check for updates*
- English and Hungarian UI (follows the Windows language)

## Requirements

- Windows 10/11 with either
  - [Docker Desktop](https://www.docker.com/products/docker-desktop/) (WSL2 backend), or
  - Docker Engine installed inside a WSL2 distro (no Docker Desktop; the daemon must start with the distro, e.g. with systemd enabled)
- A GitHub **fine-grained personal access token**:
  - Resource owner: your organization
  - Organization permissions → **Self-hosted runners: Read and write**

## Install

In PowerShell:

```powershell
irm https://github.com/HunKonTech/docker-runner-autoscaler/releases/latest/download/install.ps1 | iex
```

The installer asks whether Docker Desktop or Docker in WSL is installed (and which WSL distro), then for your organization and token, installs to `%LOCALAPPDATA%\DockerRunnerAutoscaler`, adds a Startup shortcut, registers the app in *Settings → Apps → Installed apps* and starts the tray app.

Then use the runners in your workflows:

```yaml
runs-on: [self-hosted, linux, docker]
```

## Configuration

All files are in `%LOCALAPPDATA%\DockerRunnerAutoscaler`:

| File | Purpose |
|---|---|
| `.env` | Token, organization / repository, runner name prefix, labels (see `.env.example`) |
| `settings.json` | Autoscaler settings (optional, see `settings.example.json`) |
| `docker-compose.yml` | Runner container definition. Updates ship a new one as `docker-compose.yml.new` and never overwrite yours |

`settings.json` keys:

| Key | Default | Meaning |
|---|---|---|
| `Language` | `auto` | `auto`, `en`, `hu` |
| `DockerEngine` | `desktop` | `desktop` (Docker Desktop) or `wsl` (Docker Engine inside a WSL distro, called through `wsl.exe`) |
| `WslDistro` | `""` | WSL distro running Docker when `DockerEngine` is `wsl`; empty = default distro |
| `MinRunners` | `1` | Runners always kept in automatic mode |
| `IdleBuffer` | `1` | Idle runners kept ready |
| `GbPerRunner` | `2` | Estimated memory per busy runner. The recommended maximum is `min(CPU threads, RAM / GbPerRunner)`, where RAM is the larger of the host's physical memory and the Docker VM's memory |
| `MaxRunners` | `50` | Upper limit for manual mode |
| `PollSec` | `10` | Check interval |
| `ScaleDownDelay` | `120` | Seconds a surplus must last before scaling down |
| `AutoUpdate` | `true` | Install new releases automatically |
| `UpdateCheckHours` | `6` | Update check interval |

### Docker VM resources

Docker Desktop's WSL2 VM gets half of the RAM by default. To give it more, create `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=32GB
processors=12
swap=16GB
```

Then run `wsl --shutdown` and restart Docker Desktop.

## Uninstall

Either of these works:

- *Settings → Apps → Installed apps* → **Docker Runner Autoscaler** → *Uninstall*
- Tray icon right-click → **Uninstall...**

It asks for confirmation and then:

1. stops the tray app and the autoscaler and removes the Startup shortcut,
2. optionally stops the runner containers (`docker compose down`) and deletes the offline runners left behind on GitHub,
3. deletes the program files (`app\`, `state\`). Your configuration (`.env`, `settings.json`, `docker-compose.yml`) is kept unless you choose to delete it too.

From the command line (no prompts):

```powershell
# -StopRunners: stop the runners too, -Purge: also delete the configuration (the whole install folder)
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\DockerRunnerAutoscaler\app\uninstall.ps1" -StopRunners -Purge
```

## Console keys

| Key | Action |
|---|---|
| ↑ / ↓ | Change target |
| Enter | Apply target (manual mode) |
| A | Target = recommended |
| M | Toggle automatic / manual |
| Q | Quit (autoscaling keeps running) |

## Tools

```powershell
# remove offline runners left behind (e.g. after a crash)
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\DockerRunnerAutoscaler\app\cleanup-runners.ps1"
```

## Security

- Runners mount the Docker socket so jobs can build images. **Use them only for trusted (private) repositories.** Keep public repositories disabled in the runner group.
- The token is stored in plain text in `.env` in your user profile.

## Limitations

- Docker Desktop starts only after you sign in to Windows, so the runners start then too. Enable automatic sign-in if the machine must work unattended after a reboot.

## Development

```powershell
git clone https://github.com/HunKonTech/docker-runner-autoscaler
cd docker-runner-autoscaler
powershell -ExecutionPolicy Bypass -File install.ps1 -Source .
powershell -File tests/parse.ps1; powershell -File tests/unit.ps1
```

`.ps1` files must be **UTF-8 with BOM** (Windows PowerShell 5.1). CI checks this.

**Releases**: every push to `main` (except Markdown/LICENSE-only changes) runs the [Release workflow](.github/workflows/release.yml) on a self-hosted Linux runner. It runs the tests and publishes `v<MAJOR.MINOR>.<run number>`. `MAJOR.MINOR` is the `VERSION` env value in the workflow. Installed apps update themselves.

The workflow then announces the release on X through [Buffer](https://buffer.com) (`scripts/post_buffer_release.py`). Set the `BUFFER_API_KEY` repository secret to enable it (without it the step is skipped). Optional repository variables: `BUFFER_CHANNEL_ID` or `BUFFER_CHANNEL_NAME`, `BUFFER_ORGANIZATION_ID`, `BUFFER_POST_MODE` (default `shareNow`), `BUFFER_POST_TEMPLATE`.

---

## Magyarul

GitHub Actions self-hosted Linux runnerek **Docker Desktopban, Windowson**, automatikus skálázással és tálcaikonnal.

**Telepítés** PowerShellben:

```powershell
irm https://github.com/HunKonTech/docker-runner-autoscaler/releases/latest/download/install.ps1 | iex
```

A telepítő megkérdezi, hogy Docker Desktop vagy WSL-es Docker (és melyik WSL disztribúció) van a gépen, majd elkéri az organization nevét és a tokent. Fine-grained PAT kell, ezzel a joggal: *Organization permissions → Self-hosted runners: Read and write*.

- **Tálcaikon:** a futó runnerek számát mutatja, kattintásra megnyílik az élő konzol.
- **Automatikus mód:** mindig tart 1 tétlen runnert, és felskáláz, ha mind foglalt. A fölösleget 2 perc után állítja le, a dolgozó runnert soha.
- **Kézi mód:** a nyilakkal állíthatod a runnerek számát, Enterrel alkalmazod.
- **Frissítés:** automatikusan települ, kézzel a tálca menüjéből: *Frissítés keresése*.
- **Beállítások:** `%LOCALAPPDATA%\DockerRunnerAutoscaler\settings.json` (lásd fent).
- **Nyelv:** a Windows nyelvét követi, vagy állítsd be: `"Language": "hu"`.
- **Eltávolítás:** *Gépház → Alkalmazások → Telepített alkalmazások* → **Docker Runner Autoscaler** → *Eltávolítás*, vagy a tálcaikon menüjéből: **Eltávolítás...** Megerősítés után leállítja az appot, kérésre a runnereket is, és törli a programfájlokat. A beállítások (`.env`, `settings.json`) csak akkor törlődnek, ha ezt is választod.

## Sponsor

If this project saves you time, you can support its development: [sponsor BenKoncsik on GitHub](https://github.com/sponsors/BenKoncsik). / Ha hasznos számodra a projekt, támogathatod a fejlesztést: [BenKoncsik támogatása a GitHubon](https://github.com/sponsors/BenKoncsik).

## License

[GPL-3.0](LICENSE)
