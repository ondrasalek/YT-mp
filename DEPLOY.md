# Nasazení

Jeden a tentýž image, dva způsoby nasazení podle toho, co je před aplikací.

| Scénář | Soubor | Proxy / HTTPS | Image |
|--------|--------|---------------|-------|
| **Coolify** (vedle Gitea na Oracle) | `docker-compose.coolify.yml` | řeší **Coolify** | z registry (arm64) |
| **Samostatný VPS** | `docker-compose.yml` | vlastní **Caddy** | build lokálně |

---

## A) Coolify (doporučeno pro Oracle vedle git.slks.cz)

Aplikace běží jen jako jeden kontejner na portu `8080`; doménu, TLS a routování
řeší Coolify. **Nepoužívej** vlastní Caddy (konflikt o porty 80/443).

1. **Coolify → New Resource → Docker Compose** a vlož `docker-compose.coolify.yml`
   (případně *Docker Image* → `git.slks.cz/ondrej/yt-mp:0.3.1`).
2. Pokud je registry privátní, přidej v Coolify **registry credentials**
   (`git.slks.cz`, uživatel `ondrej`, token s `read:package`).
3. Přiřaď **doménu** (např. `ytmp.slks.cz`) a cílový **port `8080`**.
4. Volitelně nastav **Environment Variables**:
   | Proměnná | Default | Význam |
   |----------|---------|--------|
   | `YTMP_TAG` | `0.3.1` | tag image v registry |
   | `YTMP_MAX_CONCURRENT` | `3` | souběžné konverze |
   | `YTMP_MAX_QUEUE` | `20` | fronta |
   | `YTMP_RATE_LIMIT` | `10` | req/min/IP |
   | `YTMP_MAX_DURATION` | `10800` | max délka videa (s) |
5. Deploy.

**Cloudflare:** doménu pro ytmp dej radši **DNS-only (šedý mrak)** — vyhneš se
100MB/SSE/timeout zádrhelům u velkých stahování a živého progressu.

## B) Samostatný VPS

Fresh server, kde před appkou nic nestojí. Build proběhne lokálně (funguje
na libovolné architektuře).

```bash
git clone <repo> && cd YT-mp

# lokální test (self-signed cert pro localhost):
docker compose up -d --build           # -> https://localhost/

# produkce s reálnou doménou:
DOMAIN=ytmp.example.com ACME_EMAIL=ty@example.com docker compose up -d --build
```

Caddy automaticky vyřídí Let's Encrypt cert a HTTP→HTTPS redirect.

---

## Společné poznámky

- **YouTube bot-check z datacenter IP** (Oracle): může vyžadovat cookies.
  Nahraj `cookies.txt`, namountuj přes volume a přidej `--cookies=/app/cookies.txt`
  (v compose souborech jsou připravené zakomentované řádky).
- **Dočasné soubory** v `/app/data` se mažou po 30 min (TTL).
- **Architektura:** registry image je `linux/arm64`. Na x86 server buildni přes
  variantu B, nebo doplň multi-arch build do CI.
