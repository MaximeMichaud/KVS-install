# GeoIP Database Setup

KVS uses MaxMind GeoIP2 databases to detect visitor location (country, region/state).

## What You'll See Without GeoIP

In KVS Admin → Settings → System Settings:

```text
GEOIP info: ❌ <IP_ADDRESS>, N/A
Maxmind GEOIP database file path: (empty)
```

## Quick Setup (Automated via GitHub Mirror)

The setup script can automatically download GeoLite2-Country from a GitHub mirror:

```bash
cd /opt/kvs/docker
./setup.sh
# When prompted "Download GeoIP database?", select "Yes"
```

This downloads from [P3TERX/GeoLite.mmdb](https://github.com/P3TERX/GeoLite.mmdb) (updated every few days).

## Download Options

### Option 1: GitHub Mirror (Quick)

**Recommended for most users** - No account needed, instant download.

```bash
cd /opt/kvs/docker
curl -fsSL https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-Country.mmdb -o geoip/GeoLite2-Country.mmdb
```

### Option 2: MaxMind Direct (Official, requires free account)

**⚠️ Not Yet Implemented** - Will be added in future release.

MaxMind offers free GeoLite2 databases via their official download API. This requires:

- Free MaxMind account: [Sign up](https://www.maxmind.com/en/geolite2/signup)
- License key (free, generated in account dashboard)
- API endpoint for automated downloads

**Database types:**

- **GeoLite2-Country.mmdb** - Country code and name
  - Example: `🇺🇸 United States`, `🇨🇦 Canada`
- **GeoLite2-City.mmdb** - Country + state/region + city
  - Example: `🇺🇸 United States, California, Los Angeles`

Future implementation will support:

```bash
# Not yet available
./setup.sh --geoip-maxmind --license-key YOUR_KEY_HERE
```

For now, download manually from [MaxMind Downloads](https://www.maxmind.com/en/accounts/current/geoip/downloads) and copy to `docker/geoip/`.

## Installation

Once you have the `.mmdb` file in this directory:

```bash
# The file should be here
ls -la /opt/kvs/docker/geoip/GeoLite2-Country.mmdb

# Restart containers to mount the database
cd /opt/kvs/docker
docker compose restart php-fpm cron

# KVS will automatically detect and configure the path
```

## Verify It Works

1. Go to KVS Admin → Settings → System Settings
2. Check "GEOIP info" field
3. You should see: `✅ <Your_IP>, <Country_Name>`

## Container Path

The database is mounted at:

- **Host:** `/opt/kvs/docker/geoip/*.mmdb`
- **Container:** `/usr/share/geoip/*.mmdb`
- **KVS setting:** Automatically configured to `/usr/share/geoip/GeoLite2-Country.mmdb` (or City)

## Updating the Database

MaxMind updates GeoLite2 databases every few days. To update:

```bash
# Auto-download latest version (if using P3TERX mirror)
cd /opt/kvs/docker
curl -fsSL https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-Country.mmdb -o geoip/GeoLite2-Country.mmdb

# OR manually download from MaxMind and replace old file
cp GeoLite2-Country_*/GeoLite2-Country.mmdb /opt/kvs/docker/geoip/

# Restart PHP to reload
docker compose restart php-fpm cron
```

## Alternative: Use Cloudflare (Recommended)

**If your site uses Cloudflare CDN, you DON'T need MaxMind GeoIP at all!**

Cloudflare automatically adds the `CF-IPCountry` header to every request. KVS detects this and uses it for geolocation.

Benefits:

- ✅ No database file needed
- ✅ Always up-to-date (Cloudflare maintains it)
- ✅ Faster (no database lookups)
- ✅ More accurate (Cloudflare's own IP data)

To use Cloudflare GeoIP:

1. Enable Cloudflare proxy (orange cloud ☁️) on your DNS records
2. Done! KVS automatically detects `$_SERVER['HTTP_CF_IPCOUNTRY']`
3. Verify in KVS Admin → Settings → System Settings

## Troubleshooting

### "File not found" error

- Verify file exists: `ls -la /opt/kvs/docker/geoip/`
- Check file is named exactly `GeoLite2-Country.mmdb` or `GeoLite2-City.mmdb`
- Restart containers: `docker compose restart php-fpm`

### Still showing "N/A"

- Check KVS settings: Admin → Settings → System Settings
- Path should be: `/usr/share/geoip/GeoLite2-Country.mmdb`
- Verify container can read file:

```bash
docker exec kvs-<prefix>-php ls -la /usr/share/geoip/
```

### Docker IP showing (172.x.x.x)

- This is normal if accessing from host machine
- Real visitor IPs will be detected correctly
- If behind reverse proxy, configure `X-Forwarded-For` in nginx
