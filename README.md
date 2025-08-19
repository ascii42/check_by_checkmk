# Check_MK Icinga Plugin

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![Version](https://img.shields.io/badge/version-1.0.0-orange.svg)](CHANGELOG.md)

A comprehensive Icinga/Nagios plugin that retrieves service status from Check_MK instances via REST API v2 or Web API v1, with advanced filtering capabilities and performance data collection.

## 🚀 Features

- **Dual API Support**: Works with Check_MK REST API v2 and Web API v1
- **Flexible Authentication**: Supports API tokens or automation user credentials
- **Advanced Filtering**: Include/exclude services by name or output patterns
- **Pattern Matching**: Supports exact names, wildcards, and regex patterns
- **Performance Data**: Configurable performance data collection with filtering
- **Verbose Output**: Detailed service status information with severity-based sorting
- **TLS Options**: Configurable TLS certificate verification
- **Debug Mode**: Comprehensive debugging information for troubleshooting

## 📋 Prerequisites

- **bash** (version 4.0+)
- **curl** - for HTTP requests
- **jq** - for JSON parsing
- **Check_MK** instance with API access

### Installing Dependencies

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install curl jq
```

**RHEL/CentOS/Rocky:**
```bash
sudo yum install curl jq
# or on newer versions:
sudo dnf install curl jq
```

**macOS:**
```bash
brew install curl jq
```

## 🔧 Installation

1. **Download the script:**
   ```bash
   wget https://raw.githubusercontent.com/ascii42/check_by_checkmk/main/check_by_checkmk.sh
   ```

2. **Make it executable:**
   ```bash
   chmod +x check_by_checkmk.sh
   ```

3. **Move to plugins directory:**
   ```bash
   sudo mv check_by_checkmk.sh /usr/lib/nagios/plugins/
   # or for Icinga2:
   sudo mv check_by_checkmk.sh /usr/lib/monitoring-plugins/
   ```

## 🔑 Authentication Setup

### API Token (Recommended)
1. In Check_MK, go to **Setup → Users → Edit User**
2. Generate an **Automation Secret** or **API Token**
3. Note the token for use with `-a` parameter

### Automation User
1. Create an automation user in Check_MK
2. Assign appropriate permissions for service viewing
3. Use username and secret with `-u` and `-p` parameters

## 📖 Usage

### Basic Usage

```bash
# Using API token
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -a your_api_token

# Using automation credentials
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u automation -p secret
```

### Verbose Output with Details

```bash
# Show individual service status with details
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -v -d
```

### Filtering Examples

```bash
# Include only filesystem services
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -i "Filesystem*"

# Exclude specific services
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -e "SSH,PING"

# Use regex patterns
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -i "/^CPU.*/"

# Filter by service output
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -E "No such file" -d
```

### Performance Data

```bash
# Include basic performance data
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -P

# Show only performance data
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -O

# Filter performance data
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -P -j "CPU*,Memory*"
```

## 🛠 Command Line Options

| Option | Description | Example |
|--------|-------------|---------|
| `-h, --host` | Hostname to check services for | `-h myserver` |
| `-s, --site-url` | Check_MK site URL | `-s https://cmk.example.com/mysite` |
| `-a, --api-token` | API token for authentication | `-a abc123...` |
| `-u, --user` | Automation username | `-u automation` |
| `-p, --secret` | Automation secret | `-p secret123` |
| `-V, --verify-tls` | Verify TLS certificates | `-V` |
| `-v, --verbose` | Show individual service status | `-v` |
| `-D, --debug` | Show detailed debug information | `-D` |
| `-d, --detail` | Show service details/output | `-d` (requires `-v`) |
| `-P, --perfdata` | Include extended performance data | `-P` |
| `-O, --perfdata-only` | Show only performance data | `-O` |
| `-e, --exclude` | Exclude services by name | `-e "SSH,PING"` |
| `-E, --exclude-output` | Exclude services by output | `-E "No such file"` |
| `-i, --include` | Include only matching services | `-i "Filesystem*"` |
| `-I, --include-output` | Include only matching output | `-I "OK*"` |
| `-j, --include-perfdata` | Include only these in perfdata | `-j "CPU*,Memory*"` |
| `-g, --exclude-perfdata` | Exclude these from perfdata | `-g "ESX*,Mount*"` |

## 🎯 Pattern Matching

The plugin supports three types of patterns:

### 1. Exact Names
```bash
-e "SSH"                    # Excludes service named exactly "SSH"
-i "CPU utilization"        # Includes only "CPU utilization"
```

### 2. Wildcards
```bash
-e "Filesystem *"           # Excludes all services starting with "Filesystem "
-i "*Temperature*"          # Includes services containing "Temperature"
```

### 3. Regular Expressions
```bash
-e "/^Filesystem \/.*/"     # Excludes filesystem services using regex
-i "/^CPU [0-9]+$/"         # Includes CPU services with numbers
```

## 📊 Performance Data Format

The plugin outputs performance data in Nagios/Icinga format:

```
total=15 ok=12 warning=2 critical=1 unknown=0 CPU_utilization=0 Memory_usage=1 Filesystem_/=0
```

### Extended Performance Data
When `-P` is used, additional metrics are included:
- Service state (0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN)
- State age (if available)
- Check age (if available)
- Perfometer data (if available)

## 🔧 Icinga2 Configuration Example

```bash
# Define the command
object CheckCommand "check_checkmk_services" {
  import "plugin-check-command"
  command = [ PluginDir + "/check_by_checkmk.sh" ]
  
  arguments = {
    "-h" = "$checkmk_host$"
    "-s" = "$checkmk_site_url$"
    "-u" = "$checkmk_user$"
    "-p" = "$checkmk_secret$"
    "-v" = {
      set_if = "$checkmk_verbose$"
    }
    "-d" = {
      set_if = "$checkmk_detail$"
    }
    "-P" = {
      set_if = "$checkmk_perfdata$"
    }
    "-e" = "$checkmk_exclude$"
    "-i" = "$checkmk_include$"
  }
}

# Define the service
apply Service "checkmk-services" {
  import "generic-service"
  check_command = "check_checkmk_services"
  
  vars.checkmk_host = host.name
  vars.checkmk_site_url = "https://checkmk.example.com/mysite"
  vars.checkmk_user = "automation"
  vars.checkmk_secret = "your_secret"
  vars.checkmk_verbose = true
  vars.checkmk_detail = true
  vars.checkmk_perfdata = true
  vars.checkmk_exclude = "SSH,PING"
  
  assign where host.vars.checkmk_enabled == true
}
```

## 🐛 Troubleshooting

### Enable Debug Mode
```bash
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -D
```

### Common Issues

1. **"All API requests failed"**
   - Check URL format (include protocol: `https://`)
   - Verify credentials
   - Check network connectivity
   - Use `-D` for detailed debugging

2. **"Invalid JSON response"**
   - Check Check_MK version compatibility
   - Verify site URL path
   - Enable debug mode to see raw response

3. **"Required columns not found"**
   - Check Check_MK permissions
   - Verify host exists in Check_MK
   - Ensure user has access to host services

4. **TLS Certificate Errors**
   - Use `-V` to enable TLS verification
   - Or use without `-V` for self-signed certificates

### Testing Connectivity
```bash
# Test basic connectivity
curl -k -u "automation:secret" "https://checkmk.example.com/mysite/check_mk/view.py?host=myhost&view_name=host&output_format=json"
```

## 📝 Output Examples

### Basic Output
```
[OK] - All 15 services OK (REST API v1.0) | total=15 ok=15 warning=0 critical=0 unknown=0
```

### Verbose Output
```
[WARNING] - 2 warning services (REST API v1.0) | total=15 ok=12 warning=2 critical=1 unknown=0
[CRITICAL]: Filesystem /var - CRITICAL - 95% used (47.5 GB of 50.0 GB)
[WARNING]: Memory - WARNING - 85% used (6.8 GB of 8.0 GB)
[WARNING]: Load average - WARNING - 15min load: 3.45 (critical at 4.00)
[OK]: CPU utilization - OK - 23% used
[OK]: SSH - OK - SSH OK - OpenSSH_8.0 (protocol 2.0)
...
```

### Performance Data Only
```bash
./check_by_checkmk.sh -h myhost -s https://checkmk.example.com/mysite -u user -p secret -O
```
```
total=15 ok=12 warning=2 critical=1 unknown=0 CPU_utilization=0 Memory=1 Filesystem_/var=2
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes and test thoroughly
4. Commit your changes: `git commit -am 'Add feature'`
5. Push to the branch: `git push origin feature-name`
6. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 👨‍💻 Author

**Felix Longardt**
- Email: monitoring@longardt.com
- GitHub: [@ascii42](https://github.com/ascii42)

## 🔖 Version History

- **v1.0.0** (2025-08-19) - Initial release
  - REST API v2 and Web API v1 support
  - Advanced filtering capabilities
  - Performance data collection
  - Comprehensive pattern matching

## 🙏 Acknowledgments

- Check_MK team for the excellent monitoring platform
- Icinga/Nagios communities for plugin standards
- Contributors and testers

---

**Need help?** Open an issue or contact monitoring@longardt.com
