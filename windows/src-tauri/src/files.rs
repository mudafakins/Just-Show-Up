//! Disk work for sending files straight to teammates (the transfer itself runs over
//! WebRTC in the page, see src/files.ts). The page can't read or write files freely,
//! so it asks for big pieces here: pick, zip, read, write, fingerprint, reveal.

use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

/// Files being received, by transfer id.
#[derive(Default)]
pub struct Incoming(Mutex<HashMap<String, (File, PathBuf)>>);

#[derive(Serialize)]
pub struct Prepared {
    path: String,
    name: String,
    size: u64,
    /// A zip we made, to delete afterwards.
    temporary: bool,
}

/// Lets me pick files (or one folder) to send. Keeps the panel open meanwhile.
#[tauri::command]
pub async fn pick_files(app: AppHandle, folder: bool) -> Vec<String> {
    crate::set_picking(app.clone(), true);
    let window = app.get_webview_window("main");
    let picked = tauri::async_runtime::spawn_blocking(move || {
        let mut dialog = rfd::FileDialog::new().set_title(if folder { "Send a folder" } else { "Send files" });
        if let Some(window) = &window {
            dialog = dialog.set_parent(window);
        }
        if folder {
            dialog.pick_folder().map(|p| vec![p]).unwrap_or_default()
        } else {
            dialog.pick_files().unwrap_or_default()
        }
    })
    .await
    .unwrap_or_default();
    crate::set_picking(app.clone(), false);
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
    picked.into_iter().map(|p| p.to_string_lossy().into_owned()).collect()
}

/// One file as it is; a folder or several files zipped into one.
#[tauri::command]
pub async fn prepare_send(paths: Vec<String>, sender: String) -> Result<Prepared, String> {
    tauri::async_runtime::spawn_blocking(move || prepare(paths, &sender))
        .await
        .map_err(|e| e.to_string())?
}

fn prepare(paths: Vec<String>, sender: &str) -> Result<Prepared, String> {
    let paths: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
    if paths.is_empty() {
        return Err("nothing to send".into());
    }
    if paths.len() == 1 && paths[0].is_file() {
        let size = fs::metadata(&paths[0]).map_err(|e| e.to_string())?.len();
        return Ok(Prepared {
            name: file_name(&paths[0]),
            path: paths[0].to_string_lossy().into_owned(),
            size,
            temporary: false,
        });
    }
    let zip_name = if paths.len() == 1 {
        format!("{}.zip", file_name(&paths[0]))
    } else {
        let first = sender.split_whitespace().next().unwrap_or("");
        if first.is_empty() {
            format!("{} files.zip", paths.len())
        } else {
            format!("{} files from {}.zip", paths.len(), first)
        }
    };
    let folder = std::env::temp_dir().join(format!("JustShowUpOutgoing-{}", std::process::id()));
    fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
    let zip_path = folder.join(format!("{}-{}", now_millis(), zip_name));
    let mut zip = zip::ZipWriter::new(File::create(&zip_path).map_err(|e| e.to_string())?);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .large_file(true);
    // Several files go inside a folder named like the zip.
    let top = if paths.len() == 1 { String::new() } else { format!("{}/", zip_name.trim_end_matches(".zip")) };
    for path in &paths {
        add_to_zip(&mut zip, path, &format!("{}{}", top, file_name(path)), options)?;
    }
    zip.finish().map_err(|e| e.to_string())?;
    let size = fs::metadata(&zip_path).map_err(|e| e.to_string())?.len();
    Ok(Prepared { path: zip_path.to_string_lossy().into_owned(), name: zip_name, size, temporary: true })
}

fn add_to_zip(
    zip: &mut zip::ZipWriter<File>,
    path: &Path,
    name: &str,
    options: zip::write::SimpleFileOptions,
) -> Result<(), String> {
    if path.is_dir() {
        zip.add_directory(format!("{}/", name), options).map_err(|e| e.to_string())?;
        let mut entries: Vec<_> = fs::read_dir(path).map_err(|e| e.to_string())?.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let child = entry.path();
            add_to_zip(zip, &child, &format!("{}/{}", name, file_name(&child)), options)?;
        }
    } else if path.is_file() {
        zip.start_file(name, options).map_err(|e| e.to_string())?;
        let mut file = File::open(path).map_err(|e| e.to_string())?;
        std::io::copy(&mut file, zip).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// A piece of a file, as raw bytes.
#[tauri::command]
pub async fn read_chunk(path: String, offset: u64, length: u32) -> Result<tauri::ipc::Response, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut file = File::open(&path).map_err(|e| e.to_string())?;
        file.seek(SeekFrom::Start(offset)).map_err(|e| e.to_string())?;
        let mut buffer = Vec::with_capacity(length as usize);
        file.take(length as u64).read_to_end(&mut buffer).map_err(|e| e.to_string())?;
        Ok(tauri::ipc::Response::new(buffer))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn file_sha256(path: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || sha256(Path::new(&path)))
        .await
        .map_err(|e| e.to_string())?
}

fn sha256(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{:02x}", b)).collect())
}

/// Deletes a zip we made for sending.
#[tauri::command]
pub fn remove_temporary(path: String) {
    let path = PathBuf::from(path);
    if path.to_string_lossy().contains("JustShowUpOutgoing-") {
        let _ = fs::remove_file(path);
    }
}

fn downloads(app: &AppHandle) -> Result<PathBuf, String> {
    let folder = app.path().download_dir().map_err(|e| e.to_string())?.join("Just Show Up");
    fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
    Ok(folder)
}

/// Starts receiving: a hidden part file in Downloads/Just Show Up.
#[tauri::command]
pub fn recv_begin(app: AppHandle, state: tauri::State<'_, Incoming>, id: String) -> Result<(), String> {
    let id = safe_id(&id)?;
    let part = downloads(&app)?.join(format!(".{}.part", id));
    let file = File::create(&part).map_err(|e| e.to_string())?;
    state.0.lock().unwrap().insert(id, (file, part));
    Ok(())
}

/// Appends raw bytes (the request body) to a file being received ("x-id" header).
#[tauri::command]
pub fn recv_write(request: tauri::ipc::Request<'_>, state: tauri::State<'_, Incoming>) -> Result<(), String> {
    let id = request
        .headers()
        .get("x-id")
        .and_then(|v| v.to_str().ok())
        .ok_or("missing id")?
        .to_string();
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else {
        return Err("expected raw bytes".into());
    };
    let mut files = state.0.lock().unwrap();
    let (file, _) = files.get_mut(&id).ok_or("unknown transfer")?;
    file.write_all(bytes).map_err(|e| e.to_string())
}

/// Checks the fingerprint and keeps the file under its real name. Returns where it
/// was saved, or nothing if it didn't arrive intact (and deletes it).
#[tauri::command]
pub async fn recv_finish(
    app: AppHandle,
    id: String,
    name: String,
    size: u64,
    sha256: String,
) -> Result<Option<String>, String> {
    let entry = app.state::<Incoming>().0.lock().unwrap().remove(&id);
    let Some((file, part)) = entry else { return Err("unknown transfer".into()) };
    drop(file);
    let folder = downloads(&app)?;
    tauri::async_runtime::spawn_blocking(move || {
        let ok = fs::metadata(&part).map(|m| m.len() == size).unwrap_or(false)
            && self::sha256(&part).map(|h| h == sha256).unwrap_or(false);
        if !ok {
            let _ = fs::remove_file(&part);
            return Ok(None);
        }
        let target = unused(&folder, &safe_name(&name));
        fs::rename(&part, &target).map_err(|e| e.to_string())?;
        Ok(Some(target.to_string_lossy().into_owned()))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn recv_abort(state: tauri::State<'_, Incoming>, id: String) {
    if let Some((file, part)) = state.0.lock().unwrap().remove(&id) {
        drop(file);
        let _ = fs::remove_file(part);
    }
}

/// Opens Explorer with the file selected.
#[tauri::command]
pub fn reveal(path: String) {
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("explorer").arg(format!("/select,{}", path)).spawn();
    }
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open").arg("-R").arg(path).spawn();
    }
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into())
}

/// A name that can't climb out of the folder or hide itself.
fn safe_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if "/\\:*?\"<>|\0".contains(c) || c.is_control() { '-' } else { c })
        .collect();
    let cleaned = cleaned.trim().trim_start_matches('.').trim_end_matches(['.', ' ']).to_string();
    let cleaned: String = cleaned.chars().take(200).collect();
    if cleaned.is_empty() { "file".into() } else { cleaned }
}

fn safe_id(id: &str) -> Result<String, String> {
    if !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        Ok(id.to_string())
    } else {
        Err("bad transfer id".into())
    }
}

/// "name.ext", or "name 2.ext" if that's taken.
fn unused(folder: &Path, name: &str) -> PathBuf {
    let path = Path::new(name);
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| name.into());
    let ext = path.extension().map(|e| e.to_string_lossy().into_owned());
    let mut candidate = folder.join(name);
    let mut n = 2;
    while candidate.exists() {
        candidate = folder.join(match &ext {
            Some(ext) => format!("{} {}.{}", stem, n, ext),
            None => format!("{} {}", stem, n),
        });
        n += 1;
    }
    candidate
}

fn now_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}
