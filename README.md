# KVS-install | Tested with 5.5.1, 6.1.2, 6.2.1 and 6.3.2

[![ShellCheck](https://github.com/MaximeMichaud/KVS-install/workflows/ShellCheck/badge.svg)](https://github.com/MaximeMichaud/KVS-install/actions?query=workflow%3AShellCheck)
[![Codacy Badge](https://app.codacy.com/project/badge/Grade/183a53d1a8ea49619c49d6fc2514c237)](https://app.codacy.com/gh/MaximeMichaud/KVS-install/dashboard?utm_source=gh&utm_medium=referral&utm_content=&utm_campaign=Badge_grade)
[![made-with-bash](https://img.shields.io/badge/-Made%20with%20Bash-1f425f.svg?logo=image%2Fpng%3Bbase64%2CiVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyZpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw%2FeHBhY2tldCBiZWdpbj0i77u%2FIiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8%2BIDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuNi1jMTExIDc5LjE1ODMyNSwgMjAxNS8wOS8xMC0wMToxMDoyMCAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENDIDIwMTUgKFdpbmRvd3MpIiB4bXBNTTpJbnN0YW5jZUlEPSJ4bXAuaWlkOkE3MDg2QTAyQUZCMzExRTVBMkQxRDMzMkJDMUQ4RDk3IiB4bXBNTTpEb2N1bWVudElEPSJ4bXAuZGlkOkE3MDg2QTAzQUZCMzExRTVBMkQxRDMzMkJDMUQ4RDk3Ij4gPHhtcE1NOkRlcml2ZWRGcm9tIHN0UmVmOmluc3RhbmNlSUQ9InhtcC5paWQ6QTcwODZBMDBBRkIzMTFFNUEyRDFEMzMyQkMxRDhEOTciIHN0UmVmOmRvY3VtZW50SUQ9InhtcC5kaWQ6QTcwODZBMDFBRkIzMTFFNUEyRDFEMzMyQkMxRDhEOTciLz4gPC9yZGY6RGVzY3JpcHRpb24%2BIDwvcmRmOlJERj4gPC94OnhtcG1ldGE%2BIDw%2FeHBhY2tldCBlbmQ9InIiPz6lm45hAAADkklEQVR42qyVa0yTVxzGn7d9Wy03MS2ii8s%2BeokYNQSVhCzOjXZOFNF4jx%2BMRmPUMEUEqVG36jo2thizLSQSMd4N8ZoQ8RKjJtooaCpK6ZoCtRXKpRempbTv5ey83bhkAUphz8fznvP8znn%2B%2F3NeEEJgNBoRRSmz0ub%2FfuxEacBg%2FDmYtiCjgo5NG2mBXq%2BH5I1ogMRk9Zbd%2BQU2e1ML6VPLOyf5tvBQ8yT1lG10imxsABm7SLs898GTpyYynEzP60hO3trHDKvMigUwdeaceacqzp7nOI4n0SSIIjl36ao4Z356OV07fSQAk6xJ3XGg%2BLCr1d1OYlVHp4eUHPnerU79ZA%2F1kuv1JQMAg%2BE4O2P23EumF3VkvHprsZKMzKwbRUXFEyTvSIEmTVbrysp%2BWr8wfQHGK6WChVa3bKUmdWou%2BjpArdGkzZ41c1zG%2Fu5uGH4swzd561F%2BuhIT4%2BLnSuPsv9%2BJKIpjNr9dXYOyk7%2FBZrcjIT4eCnoKgedJP4BEqhG77E3NKP31FO7cfQA5K0dSYuLgz2TwCWJSOBzG6crzKK%2BohNfni%2Bx6OMUMMNe%2Fgf7ocbw0v0acKg6J8Ql0q%2BT%2FAXR5PNi5dz9c71upuQqCKFAD%2BYhrZLEAmpodaHO3Qy6TI3NhBpbrshGtOWKOSMYwYGQM8nJzoFJNxP2HjyIQho4PewK6hBktoDcUwtIln4PjOWzflQ%2Be5yl0yCCYgYikTclGlxadio%2BBQCSiW1UXoVGrKYwH4RgMrjU1HAB4vR6LzWYfFUCKxfS8Ftk5qxHoCUQAUkRJaSEokkV6Y%2F%2BJUOC4hn6A39NVXVBYeNP8piH6HeA4fPbpdBQV5KOx0QaL1YppX3Jgk0TwH2Vg6S3u%2BdB91%2B%2FpuNYPYFl5uP5V7ZqvsrX7jxqMXR6ff3gCQSTzFI0a1TX3wIs8ul%2Bq4HuWAAiM39vhOuR1O1fQ2gT%2F26Z8Z5vrl2OHi9OXZn995nLV9aFfS6UC9JeJPfuK0NBohWpCHMSAAsFe74WWP%2BvT25wtP9Bpob6uGqqyDnOtaeumjRu%2ByFu36VntK%2FPA5umTJeUtPWZSU9BCgud661odVp3DZtkc7AnYR33RRC708PrVi1larW7XwZIjLnd7R6SgSqWSNjU1B3F72pz5TZbXmX5vV81Yb7Lg7XT%2FUXriu8XLVqw6c6XqWnBKiiYU%2BMt3wWF7u7i91XlSEITwSAZ%2FCzAAHsJVbwXYFFEAAAAASUVORK5CYII%3D)](https://www.gnu.org/software/bash/)
[![GNU Licence](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://github.com/MaximeMichaud/KVS-install/blob/main/LICENSE)

This script automates the setup and configuration of Kernel Video Sharing (KVS), ensuring **optimal performance** and **security** with minimal dependencies and **stable** LTS packages.

We strongly recommend all users to thoroughly read this README.md to fully understand the features, limitations, and development aspects of the script.


## Usage

```bash
bash <(curl -s https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh)
```

### Headless Usage

Using the script in headless mode is ideal for saving time during mass installations. This mode can facilitate the setup of multiple KVS sites per machine if desired by the user. However, some interactions may still be required to fine-tune specific configurations.

We are actively working to improve mass installation capabilities to allow the script to handle multiple site installations on a single machine seamlessly. To fully understand the available options and their implications, we recommend running the script in its standard mode initially. 

This approach will help you appreciate the detailed descriptions and choices provided during the setup process.


```bash
curl -fsSL https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh -o kvs-install.sh
chmod +x kvs-install.sh
HEADLESS=y \
database_ver=11.8 \
IONCUBE=YES \
AUTOPACKAGEUPDATE=YES \
./kvs-install.sh
```

## Compatibility

The latest versions are more stable and we recommended using Debian 12 for the best support.

This script supports the following Linux distributions:

| Operating System       | Support |
|-------------------|---------|
| Debian 11         | ✅       |
| Debian 12         | ✅       |
| Debian 13         | ✅       |

At present, non-Debian-based distros are not a priority. We recommend using the latest stable version of Debian as it was the development platform for this script. If you wish to use another distro, please open an issue on GitHub with a valid reason for consideration. Your case will be studied, and may provide support through Docker to achieve similar results.


### Hardware Recommendations

This script does not have specific minimum requirements, but we recommend using an SSD for KVS and an HDD for mass storage. 

Additionally, certain configurations may need to be modified based on your site's needs, such as the number of PHP workers. 

However, in general, you should be fine even with a site experiencing a high amount of traffic, unless you have specific usage patterns or inefficient code. This is why SSDs are important, or other measures may need to be implemented to improve performance if it becomes problematic.

### Tested Environment

**Development**: The script has been tested on a system with at least 1 vCPU, 2GB of RAM, and a 10GB SSD, proving sufficient for basic setup and testing.

**Production**: For production environments, we recommend a server configuration with more cores, increased RAM, and significantly more storage. KVS runs efficiently with an optimal configuration; however, performance heavily depends on the SSD speed, KVS theme, and custom plugins. Typically, the database is the most resource-intensive component. Configuring Sphinx can mitigate CPU load if necessary.

In a test on Debian 11, a standard installation left 6.3GB free out of 10GB. Watch demo 6 May 2023: [Demo Video](https://www.youtube.com/watch?v=WIa3xobMBR4).

## Features

- **Automated KVS Setup**: Installs all necessary dependencies, sets up the database, configures cron jobs, and prepares the webserver. Tailored to meet the [KVS requirements](https://www.kernel-video-sharing.com/en/requirements/).
- **Optimized Web Server Configuration**: Configures NGINX with the latest performance and security enhancements including HTTP/2 with ALPN, 0-RTT support for TLS 1.3, and x25519 support. Configurations are aligned with [Qualys SSL Labs](https://www.ssllabs.com/ssltest/) and Mozilla Foundation security standards, ensuring broad compatibility without compromising on security.
- **SSL Configuration via ACME.sh**: Automatically handles SSL certificate issuance and renewal using ACME.sh with ECDSA support for enhanced security.
- **Dynamic PHP Configuration**: Adjusts PHP settings based on the server's RAM to optimize KVS performance. Utilizes dynamic settings for systems with less than 4GB of RAM and static settings for systems with more (may require tuning depending on your traffic or if PHP workers use more RAM than average).
- **Extended PHP Support**: Uses Sury's repository to provide extended PHP version support, incorporating security updates from [Freexian's Debian LTS project](https://www.freexian.com/lts/debian/).
- **Memcached Configuration**: Sets Memcached memory allocation to a level suited for high traffic websites, optimizing cache performance.
- **Automated Updates**: Enables automatic updates for all installed packages and added repositories to keep the server secure and up-to-date.
- **Domain Configuration**: Automatically configures the server domain based on the uploaded CMS license, ensuring correct system operation. DNS zone configuration is still required.
- **MariaDB Latest LTS**: Installs the latest LTS version of MariaDB, offering more up-to-date solutions than standard repository versions with options to select preferred LTS versions.
- **Resource Monitoring Tools**: Includes additional packages like ncdu, vnstat, and nload for resource monitoring.
- **Optional IonCube Installation**: Provides the option to install or skip IonCube depending on licensing needs.
- **YT-DLP Installation**: Installs the latest version of yt-dlp, a fork of youtube-dl, ensuring up-to-date media downloading capabilities.

## To-Do

Features are continuously being developed to enhance the script, ensuring it remains comprehensive and up-to-date. For a detailed view of ongoing and planned improvements, visit the [project page](https://github.com/users/MaximeMichaud/projects/2).

If you have suggestions or questions, please feel free to open an issue on GitHub with the 'enhancement' or 'question' label. 

Current priorities include increasing SSL flexibility to support configurations such as Cloudflare, improving NGINX configurations (e.g., handling `CF-Connecting-IP`), and integrating Cloudflare settings via API. We are also focused on enhancing testing protocols to identify bugs more efficiently and verifying that the installation is functional and optimized across all script components after completion.

Your input is valuable— if you believe certain enhancements should be prioritized, please let us know.

## Supports

The technologies used depend on what KVS supports, which means that some may not be the most up-to-date if KVS has not yet provided support for them. (For example, PHP 8.3/8.4 is not yet officially supported by KVS and thus not recommended.)

* NGINX 1.29.x mainline
* MariaDB 10.6 LTS, 10.11 LTS, 11.4 LTS or 11.8 LTS (Default)
* PHP 7.4 or PHP 8.1 (since 6.2.0)
* phpMyAdmin 5.2.3 (or newer)

## Customization and Limitations

While this script is designed for a straightforward deployment on systems that do not already have a web server setup, it may require adjustments based on your server's specific setup and traffic needs. Here are a few points to consider:

- **Existing LEMP Stacks**: If you already have a LEMP stack installed and are familiar with its configuration, you may opt to use the NGINX configuration provided in this repository. This allows you to leverage the optimizations without running the script.
- **Server Configuration Understanding**: It is beneficial to review the functions within the script to understand the recommended configurations for NGINX, PHP-FPM, and Memcached. Specifically, the script adjusts NGINX to align with PHP-FPM settings and increases Memcached's default memory allocation, which is typically insufficient in default distribution installations.
- **Web Server Compatibility**: The script is optimized for NGINX and does not support other web servers such as Apache2, LiteSpeed, or Caddy. If your environment uses these or other web servers, manual configuration adjustments will be necessary.
- **Distro Compatibility**: This script is primarily designed for use with Debian-based distributions.

These points should help you tailor the installation to your needs, providing a deeper understanding of the Kernel Video Sharing platform configuration requirements and ensuring optimal performance.

## Contributing

Contributions to the script are welcome! If you have improvements or bug fixes, please fork the repository and submit a pull request.