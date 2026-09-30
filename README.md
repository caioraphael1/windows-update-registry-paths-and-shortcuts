# Windows Registry Update Paths

- Replaces an old application path with a new one across the registry.
- As a bonus, it also update shortcuts in the directories: `Desktop`, `CommonDesktopDirectory`, `StartMenu`, `CommonStartMenu`, `SendTo`. Any other directories can be added on `registry_update_paths.ps1:241`.


## Why?

- This is useful when moving the installation path of a app used in the registry.
- For example, if you move the installation path of 'VSCodium' (VSCode fork): 
    - any entry in the context-menu (right click) will break;
    - any file association will break (you'll be prompted to open with a new app, as the previous one was not found)
    - previous icons from this installation folder will break.



## Features

- Case-insensitive matching.
- Matches path variants: `C:\x`, `C:/x`, `C:\\x`, and `%ENVVAR%\...` forms, built from your environment variables.
- Handles REG_SZ, REG_EXPAND_SZ (type preserved) and REG_MULTI_SZ (each element).
- Also renames VALUE NAMES that contain the path (AppCompatFlags\Layers, MuiCache, ...).
- Scans HKCU\Software (incl. Classes), HKLM\Software (incl. Wow6432Node and Classes),
both Environment keys (PATH etc.) and HKLM\...\Services (ImagePath).
- Uses the 64-bit registry view even from a 32-bit PowerShell.
- REG_BINARY values and key NAMES that contain the path are REPORTED but never changed,
because editing them blindly can corrupt them.
- Optional: backup, other loaded user profiles, and .lnk shortcut fixing.
- After a real run it broadcasts a "file associations changed" notification so Explorer
refreshes icons without needing to be killed.



## Usage

- `OldPath`
    - Old folder (or file) path.
- `NewPath`
    - New folder (or file) path.
- `Preview`
    - `$True`  = only show what would change.
    - `$False` = apply.
- `BackupDir`
    - (optional) Folder for `.reg` backups, made before any change, only used if `Preview = $False`.

- Run from an elevated PowerShell (administrator) to change HKLM entries.


### Examples

- Preview:
```sh
.\registry_update_paths.ps1 `
    -OldPath 'C:\Users\caior\AppData\Local\Programs\VSCodium' `
    -NewPath 'C:\caio\apps_source\vscodium' `
    -Preview $True
```

- Apply without backup: 
```sh
.\registry_update_paths.ps1 `
    -OldPath 'C:\Users\caior\AppData\Local\Programs\VSCodium' `
    -NewPath 'C:\caio\apps_source\vscodium' `
    -Preview $False
```

- Apply with backup: 
```sh
.\registry_update_paths.ps1 `
    -OldPath 'C:\Users\caior\AppData\Local\Programs\VSCodium' `
    -NewPath 'C:\caio\apps_source\vscodium' `
    -Preview $False
    -BackupDir "$env:USERPROFILE\reg-backup"
```
