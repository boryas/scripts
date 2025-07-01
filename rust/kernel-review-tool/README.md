# Kernel Review Tool

A Rust tool for Linux kernel code review that uses `lei` to fetch emails from lore.kernel.org and identifies unreviewed patches.

## Features

- **Lei Integration**: Fetches kernel mailing list emails using lei
- **Message-ID Threading**: Proper email threading for series organization  
- **Review Rules**: Sophisticated rules where cover letter reviews apply to all patches
- **Version Handling**: Deduplication of patch versions
- **Maildir Output**: Compatible with mutt and other mail clients
- **TOML Configuration**: Easy configuration for different mailing lists

## Usage

### Basic Usage
```bash
# Use default query (patches from last week)
./kernel-review-tool

# Custom query
./kernel-review-tool --query "s:PATCH AND f:author@example.com"

# Verbose output with debug emails
./kernel-review-tool --verbose --debug-all all-emails
```

### TOML Configuration

Use a TOML config file to easily target specific mailing lists:

```bash
./kernel-review-tool --config my-config.toml
```

#### Sample Config Files

**General kernel patches (config.toml):**
```toml
mailing_list = "linux-kernel@vger.kernel.org"
days_back = 7
additional_filters = ""
```

**Btrfs filesystem patches (btrfs-config.toml):**
```toml
mailing_list = "linux-btrfs@vger.kernel.org"  
days_back = 14
additional_filters = "s:btrfs"
```

**Networking patches (net-config.toml):**
```toml
mailing_list = "netdev@vger.kernel.org"
days_back = 3
additional_filters = "nrt:stable@vger.kernel.org"
```

#### Config Options

- `mailing_list`: Target mailing list (empty string for all lists)
- `days_back`: Number of days back to search
- `additional_filters`: Optional lei query filters

## Command Line Options

```
Options:
  -q, --query <QUERY>    Lei search query [default: "s:PATCH AND dt:1.week.ago.."]
  -o, --output <DIR>     Output Maildir directory for unreviewed patches [default: unreviewed]
  -v, --verbose          Verbose output
      --debug-all <DIR>  Output all queried emails to a debug Maildir
  -c, --config <FILE>    TOML configuration file
  -h, --help             Print help
```

## Requirements

- `lei` command from public-inbox
- Rust toolchain for building

## Building

```bash
cargo build --release
```