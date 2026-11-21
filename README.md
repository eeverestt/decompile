# Mod Decompiler

A command-line tool for converting compiled mods into readable Java source code.

## Prerequisites

Before installing, make sure you have the following installed and available on your `PATH`:

* **[.NET SDK](https://microsoft.com)** *(Required to build the tool from source)*
* **[Java Runtime Environment (JRE)](https://adoptium.net)** *(Required to run the decompiler at runtime)*

## Install

### Windows

Open **PowerShell** and run:

```powershell
irm https://githubusercontent.com | iex
```

This downloads the latest source from `main`, compiles a self-contained `decompile.exe` into `%LOCALAPPDATA%\Programs\decompile`, and adds it to your user `PATH`.

> **Note:** Open a new terminal window after installation so your updated `PATH` takes effect, then verify with:
> ```powershell
> decompile --help
> ```

### Custom Install Directory or Uninstall

To pass arguments such as `-InstallDir` or `-Uninstall` when running from the web, invoke the script as a script block:

```powershell
# Install to a custom folder
& ([scriptblock]::Create((irm https://githubusercontent.com))) -InstallDir "C:\Tools\decompile"

# Uninstall
& ([scriptblock]::Create((irm https://githubusercontent.com))) -Uninstall
```
