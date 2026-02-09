# Slim Down
A lightweight CLI tool to clean up disk by removing files and directories matching specified patterns, with support for ignore rules.

## Features
- **Remove patterns**: Specify files or directories to delete.
- **Ignore patterns**: Protect specific paths from deletion (takes precedence over remove patterns).
- **Configuration**: Persist rules in a TOML config file.
- **Safe defaults**: Requires explicit patterns to run.

## Requirements
- Zig 0.15.x

## Usage
```sh
# Remove all .tmp files and the cache directory
slim-down -r "*.tmp" "cache/"

# Remove all build artifacts but keep the final executable
slim-down -r "build/" -i "build/bin/app"
```

### Options

| Flag | Description |
|------|-------------|
| `-r`, `--remove <PATTERN>...` | Patterns of files/directories to remove. |
| `-i`, `--ignore <PATTERN>...` | Patterns to preserve (overrides remove). |
| `-c`, `--config <PATH>` | Path to config file. |
| `--no-config` | Skip loading the configuration file. |
| `-h`, `--help` | Display help. |
| `-V`, `--version` | Display version info. |


## Configuration

You can define default patterns in a config file (TOML).

**Default Path**: `$XDG_CONFIG_HOME/slim-down/config.toml` or `~/.config/slim-down/config.toml`.

**Example `config.toml`**:

```toml
# Always remove these
remove = [
    "*.log",
    ".DS_Store",
    "tmp/",
]

# Never remove these, even if they match a remove pattern
ignore = [
    "important.log",
]
```

CLI arguments are merged with the configuration file values.
