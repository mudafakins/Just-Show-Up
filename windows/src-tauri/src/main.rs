// Just Show Up! for Windows: a tray icon with a small panel, plus a see-through
// window for drawings over a shared screen. All calling logic lives in the web code
// (src/*.ts); this file only manages windows and the tray.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod files;

use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{
    AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PhysicalSize, WebviewUrl,
    WebviewWindow, WebviewWindowBuilder, WindowEvent,
};

const PANEL_WIDTH: f64 = 320.0;

/// Every webview on Windows shares one WebView2 environment, so they must all use the
/// same browser arguments. These let ringtones and teammates' voices play without a
/// click first, and keep audio and timers running while the panel is hidden.
#[cfg(windows)]
const BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection \
    --autoplay-policy=no-user-gesture-required \
    --disable-background-timer-throttling --disable-renderer-backgrounding \
    --disable-backgrounding-occluded-windows";

#[derive(Default)]
struct AppState {
    /// A file picker is open, so losing focus must not hide the panel.
    picking: Mutex<bool>,
    /// The main window is showing a teammate's screen rather than the panel.
    viewer: Mutex<bool>,
    /// When the panel last hid because it lost focus (clicking the tray icon does that
    /// first, and the click must not then reopen it).
    hidden_at: Mutex<Option<Instant>>,
    /// The tray icon's last known position, in physical pixels: x, y, width, height.
    tray: Mutex<Option<(f64, f64, f64, f64)>>,
    panel_height: Mutex<f64>,
}

fn builder<'a>(app: &'a AppHandle, label: &'a str, page: &str) -> WebviewWindowBuilder<'a, tauri::Wry, AppHandle> {
    let b = WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into()));
    #[cfg(windows)]
    let b = b.additional_browser_args(BROWSER_ARGS);
    b
}

fn main_window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("main")
}

/// Puts the panel next to the tray icon: above it when the taskbar is at the bottom
/// (Windows), below it when the menu bar is at the top (macOS, for testing).
fn place_panel(app: &AppHandle, window: &WebviewWindow) {
    let state = app.state::<AppState>();
    let scale = window.scale_factor().unwrap_or(1.0);
    let height = *state.panel_height.lock().unwrap();
    let (w, h) = (PANEL_WIDTH * scale, height.max(200.0) * scale);
    let _ = window.set_size(LogicalSize::new(PANEL_WIDTH, height.max(200.0)));

    let tray = *state.tray.lock().unwrap();
    let monitor = window.primary_monitor().ok().flatten();
    let (x, y) = match (tray, &monitor) {
        (Some((tx, ty, tw, th)), Some(m)) => {
            let screen = m.size();
            let mut x = tx + tw / 2.0 - w / 2.0;
            x = x.clamp(8.0, screen.width as f64 - w - 8.0);
            let y = if ty > screen.height as f64 / 2.0 { ty - h - 8.0 } else { ty + th + 8.0 };
            (x, y)
        }
        (_, Some(m)) => {
            // No tray position yet: bottom-right, above the taskbar.
            let area = m.work_area();
            (
                area.position.x as f64 + area.size.width as f64 - w - 12.0,
                area.position.y as f64 + area.size.height as f64 - h - 12.0,
            )
        }
        _ => (100.0, 100.0),
    };
    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}

fn show_panel_window(app: &AppHandle) {
    let Some(window) = main_window(app) else { return };
    if *app.state::<AppState>().viewer.lock().unwrap() {
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    place_panel(app, &window);
    let _ = window.show();
    let _ = window.set_focus();
    let _ = app.emit("panel-shown", ());
}

fn toggle_panel(app: &AppHandle) {
    let Some(window) = main_window(app) else { return };
    let state = app.state::<AppState>();
    if window.is_visible().unwrap_or(false) && !*state.viewer.lock().unwrap() {
        let _ = window.hide();
        return;
    }
    // This click is what just hid the panel (by taking focus away): leave it hidden.
    if let Some(at) = *state.hidden_at.lock().unwrap() {
        if at.elapsed() < Duration::from_millis(300) {
            return;
        }
    }
    show_panel_window(app);
}

#[tauri::command]
fn show_panel(app: AppHandle) {
    show_panel_window(&app);
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(window) = main_window(&app) {
        let _ = window.hide();
    }
}

/// The panel tells us how tall its content is, so the window fits it exactly.
#[tauri::command]
fn set_panel_height(app: AppHandle, height: f64) {
    let state = app.state::<AppState>();
    *state.panel_height.lock().unwrap() = height.clamp(160.0, 900.0);
    if *state.viewer.lock().unwrap() {
        return;
    }
    if let Some(window) = main_window(&app) {
        if window.is_visible().unwrap_or(false) {
            place_panel(&app, &window);
        }
    }
}

/// Turns the main window into a normal, resizable window showing a teammate's screen.
#[tauri::command]
fn enter_viewer(app: AppHandle, title: String) {
    let Some(window) = main_window(&app) else { return };
    *app.state::<AppState>().viewer.lock().unwrap() = true;
    let _ = window.set_title(&title);
    let _ = window.set_decorations(true);
    let _ = window.set_resizable(true);
    let _ = window.set_skip_taskbar(false);
    let _ = window.set_always_on_top(false);
    let _ = window.set_size(LogicalSize::new(1100.0, 700.0));
    let _ = window.center();
    let _ = window.show();
    let _ = window.set_focus();
}

/// Back to the small panel by the tray icon (hidden until the icon is clicked).
#[tauri::command]
fn enter_panel(app: AppHandle, show: bool) {
    let Some(window) = main_window(&app) else { return };
    *app.state::<AppState>().viewer.lock().unwrap() = false;
    let _ = window.set_title("Just Show Up!");
    let _ = window.set_decorations(false);
    let _ = window.set_resizable(false);
    let _ = window.set_skip_taskbar(true);
    let _ = window.set_always_on_top(true);
    if show {
        show_panel_window(&app);
    } else {
        let _ = window.hide();
    }
}

/// Opens the see-through drawing layer over the monitor whose shape matches what I'm sharing.
#[tauri::command]
fn open_overlay(app: AppHandle, aspect: f64) -> Result<(), String> {
    close_overlay(app.clone());
    let main = main_window(&app).ok_or("no main window")?;
    let monitors = main.available_monitors().map_err(|e| e.to_string())?;
    let primary = main.primary_monitor().ok().flatten();
    let ratio = |m: &tauri::Monitor| m.size().width as f64 / m.size().height.max(1) as f64;
    let mut best = primary.clone();
    if monitors.len() > 1 && aspect > 0.0 {
        best = monitors
            .into_iter()
            .min_by(|a, b| (ratio(a) - aspect).abs().total_cmp(&(ratio(b) - aspect).abs()))
            .or(primary);
    }
    let monitor = best.ok_or("no monitor")?;

    let overlay = builder(&app, "overlay", "overlay.html")
        .title("Just Show Up! drawings")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .focused(false)
        .visible(false)
        .build()
        .map_err(|e| e.to_string())?;
    let _ = overlay.set_position(*monitor.position());
    let _ = overlay.set_size(PhysicalSize::new(monitor.size().width, monitor.size().height));
    set_click_through(&overlay, true);
    let _ = overlay.show();
    Ok(())
}

/// Lets clicks pass through the overlay (or not, in draw mode).
///
/// On Windows, click-through makes the window "layered", and Windows doesn't draw a
/// layered window until it has been given its opacity, which tao never does. So give
/// it full opacity; the page's own transparency still shows the screen underneath.
fn set_click_through(overlay: &WebviewWindow, on: bool) {
    let _ = overlay.set_ignore_cursor_events(on);
    #[cfg(windows)]
    if on {
        if let Ok(hwnd) = overlay.hwnd() {
            use windows_sys::Win32::UI::WindowsAndMessaging::{SetLayeredWindowAttributes, LWA_ALPHA};
            unsafe {
                SetLayeredWindowAttributes(hwnd.0 as _, 0, 255, LWA_ALPHA);
            }
        }
    }
}

#[tauri::command]
fn close_overlay(app: AppHandle) {
    if let Some(overlay) = app.get_webview_window("overlay") {
        let _ = overlay.destroy();
    }
}

/// Draw mode: the overlay takes the mouse so I can draw on my own screen.
#[tauri::command]
fn set_overlay_interactive(app: AppHandle, on: bool) {
    if let Some(overlay) = app.get_webview_window("overlay") {
        set_click_through(&overlay, !on);
        if on {
            let _ = overlay.set_focus();
        }
    }
}

/// Keeps the panel open while a file picker (e.g. for a profile photo) is showing.
#[tauri::command]
fn set_picking(app: AppHandle, on: bool) {
    *app.state::<AppState>().picking.lock().unwrap() = on;
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(AppState {
            panel_height: Mutex::new(420.0),
            ..Default::default()
        })
        .invoke_handler(tauri::generate_handler![
            show_panel,
            hide_panel,
            set_panel_height,
            enter_viewer,
            enter_panel,
            open_overlay,
            close_overlay,
            set_overlay_interactive,
            set_picking,
            quit,
            files::pick_files,
            files::prepare_send,
            files::read_chunk,
            files::file_sha256,
            files::remove_temporary,
            files::recv_begin,
            files::recv_write,
            files::recv_finish,
            files::recv_abort,
            files::reveal
        ])
        .manage(files::Incoming::default())
        .setup(|app| {
            let handle = app.handle().clone();

            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            builder(&handle, "main", "index.html")
                .title("Just Show Up!")
                .inner_size(PANEL_WIDTH, 420.0)
                .decorations(false)
                .resizable(false)
                .skip_taskbar(true)
                .always_on_top(true)
                .visible(false)
                .build()?;

            let quit_item = MenuItem::with_id(app, "quit", "Quit Just Show Up!", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&quit_item])?;
            let mut tray = TrayIconBuilder::with_id("tray")
                .tooltip("Just Show Up!")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| {
                    if event.id() == "quit" {
                        app.exit(0);
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        rect,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        let scale = main_window(app).and_then(|w| w.scale_factor().ok()).unwrap_or(1.0);
                        let p = rect.position.to_physical::<f64>(scale);
                        let s = rect.size.to_physical::<f64>(scale);
                        *app.state::<AppState>().tray.lock().unwrap() = Some((p.x, p.y, s.width, s.height));
                        toggle_panel(app);
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() != "main" {
                return;
            }
            let app = window.app_handle();
            let state = app.state::<AppState>();
            match event {
                // Like a menu: the panel goes away when you click elsewhere.
                WindowEvent::Focused(false) => {
                    if !*state.viewer.lock().unwrap() && !*state.picking.lock().unwrap() {
                        *state.hidden_at.lock().unwrap() = Some(Instant::now());
                        let _ = window.hide();
                    }
                }
                // Closing the screen viewer returns to the panel instead of quitting.
                WindowEvent::CloseRequested { api, .. } => {
                    api.prevent_close();
                    let _ = app.emit("viewer-closed", ());
                }
                _ => {}
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Just Show Up!");
}
