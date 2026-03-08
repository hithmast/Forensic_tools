# PyCarv – Python Memory Carving Tool

**PyCarv** is a high-performance PowerShell script designed to extract Python-related artifacts from **AVML** and **LiME** memory dumps.  
It leverages Sysinternals **strings64.exe** for string extraction, combined with advanced regex matching, streaming I/O, and parallel processing to handle massive dumps (100GB+) efficiently.

---

## 🔍 Features

- **Python Artifact Detection**: Identifies Python executables, scripts, modules, and environment references.
- **Regex-Based Path Extraction**: Finds `.py` file paths across Linux and Windows memory dumps.
- **Scalable Performance**:
  - Streaming I/O (no temporary disk usage)
  - Parallel job execution with configurable throttle limits
- **Flexible Output**:
  - Per-dump CSVs and text reports
  - Consolidated master CSVs for all dumps
  - Optional full ASCII string dumps
- **Unicode Support**: Optional scanning for UTF-16 strings.

---

## ⚙️ Parameters

| Parameter        | Description                                                                 | Default |
|------------------|-----------------------------------------------------------------------------|---------|
| `DumpDir`        | Directory containing `.avml` or `.lime` memory dumps. **Mandatory**         | —       |
| `OutDir`         | Output directory for results                                                | `results/` |
| `StringsExe`     | Path to Sysinternals `strings64.exe`                                        | `strings64.exe` |
| `MinLen`         | Minimum string length to extract                                            | `8`     |
| `ShowOffsets`    | Include byte offsets in results (slower but more detailed)                  | `true`  |
| `KeepFullStrings`| Save full ASCII string dump per file                                        | `true`  |
| `ThrottleLimit`  | Max number of dumps processed in parallel                                   | `12`    |
| `ScanUnicode`    | Also scan for Unicode (UTF-16) strings                                      | `false` |

---

## 🚀 Usage Examples

Run with default settings:
```powershell
.\pycarv.ps1 -DumpDir "C:\Forensics\Dumps" -OutDir "C:\Results"
```

Skip offsets for maximum speed:
```powershell
.\pycarv.ps1 -DumpDir "." -ShowOffsets $false
```

Enable Unicode scanning:
```powershell
.\pycarv.ps1 -DumpDir "D:\MemoryDumps" -ScanUnicode $true
```

---

## 📂 Output Structure

```
results/
├── raw_full_strings/     # Full ASCII dumps (optional)
├── per_dump_csv/         # CSVs with extracted strings per dump
├── per_dump_paths/       # Extracted Python file paths per dump
├── python_hits_txt/      # Raw text hits per dump
├── status/               # Status JSON files for job tracking
├── AllPythonStrings.csv  # Consolidated strings across all dumps
├── AllPythonPaths.csv    # Consolidated Python paths
└── Summary.csv           # Summary of hits per dump
```

---

## ⚠️ Requirements

- **PowerShell 5+**
- **Sysinternals strings64.exe** (must be in PATH or specified via `StringsExe`)
- Sufficient memory and CPU cores for parallel processing

---

## 📖 Notes

- Dumps smaller than 1MB are automatically skipped.
- Disabling offsets (`-ShowOffsets $false`) can increase speed up to **5x**.
- Status tracking provides live progress updates with ETA.

---

## 🤝 Contributing

Contributions are welcome!  
Please fork the repo, create a feature branch, and submit a pull request with improvements or new forensic modules.

---

## ⚠️ Disclaimer

This tool is intended for **digital forensic investigations** and **educational use**.  
The authors are not responsible for misuse or any legal implications arising from improper use.
