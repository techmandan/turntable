use std::collections::{BTreeMap, HashSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;

const ART_DIR: &str = "/tmp/turntable-cache/art";
const CATALOG_FILE: &str = "/tmp/turntable-cache/catalog_cache.json";

// ============================================================================
// Lightweight RFC 8259 JSON Parser & Serializer (Zero External Dependencies)
// ============================================================================

#[derive(Clone, Debug, PartialEq)]
enum JsonVal {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<JsonVal>),
    Obj(BTreeMap<String, JsonVal>),
}

impl JsonVal {
    fn as_str(&self) -> Option<&str> {
        match self {
            JsonVal::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }

    fn as_f64(&self) -> Option<f64> {
        match self {
            JsonVal::Num(n) => Some(*n),
            _ => None,
        }
    }

    fn as_i64(&self) -> Option<i64> {
        self.as_f64().map(|n| n as i64)
    }

    fn as_arr(&self) -> Option<&Vec<JsonVal>> {
        match self {
            JsonVal::Arr(a) => Some(a),
            _ => None,
        }
    }

    fn as_obj(&self) -> Option<&BTreeMap<String, JsonVal>> {
        match self {
            JsonVal::Obj(o) => Some(o),
            _ => None,
        }
    }

    fn as_obj_mut(&mut self) -> Option<&mut BTreeMap<String, JsonVal>> {
        match self {
            JsonVal::Obj(o) => Some(o),
            _ => None,
        }
    }

    fn get(&self, key: &str) -> Option<&JsonVal> {
        self.as_obj()?.get(key)
    }

    fn get_str(&self, key: &str) -> &str {
        self.get(key).and_then(|v| v.as_str()).unwrap_or("")
    }

    fn get_i64(&self, key: &str, default: i64) -> i64 {
        self.get(key).and_then(|v| v.as_i64()).unwrap_or(default)
    }

    fn get_f64(&self, key: &str, default: f64) -> f64 {
        self.get(key).and_then(|v| v.as_f64()).unwrap_or(default)
    }

    fn to_json_string(&self) -> String {
        let mut out = String::with_capacity(512);
        self.write_json(&mut out);
        out
    }

    fn write_json(&self, out: &mut String) {
        match self {
            JsonVal::Null => out.push_str("null"),
            JsonVal::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            JsonVal::Num(n) => {
                if n.is_finite() {
                    if (*n - n.round()).abs() < 1e-9 && n.abs() < 1e15 {
                        out.push_str(&format!("{}", *n as i64));
                    } else {
                        out.push_str(&format!("{}", n));
                    }
                } else {
                    out.push('0');
                }
            }
            JsonVal::Str(s) => {
                out.push('"');
                for ch in s.chars() {
                    match ch {
                        '"' => out.push_str("\\\""),
                        '\\' => out.push_str("\\\\"),
                        '\n' => out.push_str("\\n"),
                        '\r' => out.push_str("\\r"),
                        '\t' => out.push_str("\\t"),
                        c if (c as u32) < 0x20 => {
                            out.push_str(&format!("\\u{:04x}", c as u32));
                        }
                        c => out.push(c),
                    }
                }
                out.push('"');
            }
            JsonVal::Arr(arr) => {
                out.push('[');
                for (i, item) in arr.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_json(out);
                }
                out.push(']');
            }
            JsonVal::Obj(map) => {
                out.push('{');
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    JsonVal::Str(k.clone()).write_json(out);
                    out.push(':');
                    v.write_json(out);
                }
                out.push('}');
            }
        }
    }
}

struct JsonParser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> JsonParser<'a> {
    fn new(input: &'a str) -> Self {
        Self {
            bytes: input.as_bytes(),
            pos: 0,
        }
    }

    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.skip_ws();
        self.bytes.get(self.pos).copied()
    }

    fn parse_value(&mut self) -> Option<JsonVal> {
        let b = self.peek()?;
        match b {
            b'"' => self.parse_string().map(JsonVal::Str),
            b'{' => self.parse_object(),
            b'[' => self.parse_array(),
            b't' => {
                if self.bytes.get(self.pos..self.pos + 4) == Some(b"true") {
                    self.pos += 4;
                    Some(JsonVal::Bool(true))
                } else {
                    None
                }
            }
            b'f' => {
                if self.bytes.get(self.pos..self.pos + 5) == Some(b"false") {
                    self.pos += 5;
                    Some(JsonVal::Bool(false))
                } else {
                    None
                }
            }
            b'n' => {
                if self.bytes.get(self.pos..self.pos + 4) == Some(b"null") {
                    self.pos += 4;
                    Some(JsonVal::Null)
                } else {
                    None
                }
            }
            b'-' | b'0'..=b'9' => self.parse_number(),
            _ => None,
        }
    }

    fn parse_string(&mut self) -> Option<String> {
        self.skip_ws();
        if self.bytes.get(self.pos) != Some(&b'"') {
            return None;
        }
        self.pos += 1;
        let mut out = String::new();
        while self.pos < self.bytes.len() {
            let b = self.bytes[self.pos];
            if b == b'"' {
                self.pos += 1;
                return Some(out);
            } else if b == b'\\' {
                self.pos += 1;
                let esc = *self.bytes.get(self.pos)?;
                self.pos += 1;
                match esc {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{0008}'),
                    b'f' => out.push('\u{000c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let hex = std::str::from_utf8(self.bytes.get(self.pos..self.pos + 4)?).ok()?;
                        let code = u16::from_str_radix(hex, 16).ok()?;
                        self.pos += 4;
                        if (0xD800..=0xDBFF).contains(&code) {
                            if self.bytes.get(self.pos..self.pos + 2) == Some(b"\\u") {
                                self.pos += 2;
                                let hex2 =
                                    std::str::from_utf8(self.bytes.get(self.pos..self.pos + 4)?)
                                        .ok()?;
                                let code2 = u16::from_str_radix(hex2, 16).ok()?;
                                self.pos += 4;
                                let combined = 0x10000
                                    + (((code as u32 - 0xD800) << 10) | (code2 as u32 - 0xDC00));
                                if let Some(ch) = char::from_u32(combined) {
                                    out.push(ch);
                                }
                            }
                        } else if let Some(ch) = char::from_u32(code as u32) {
                            out.push(ch);
                        }
                    }
                    _ => out.push(esc as char),
                }
            } else {
                let rest = &self.bytes[self.pos..];
                let s = std::str::from_utf8(rest).ok()?;
                let ch = s.chars().next()?;
                out.push(ch);
                self.pos += ch.len_utf8();
            }
        }
        None
    }

    fn parse_number(&mut self) -> Option<JsonVal> {
        self.skip_ws();
        let start = self.pos;
        if self.bytes.get(self.pos) == Some(&b'-') {
            self.pos += 1;
        }
        while let Some(&b) = self.bytes.get(self.pos) {
            if b.is_ascii_digit() || b == b'.' || b == b'e' || b == b'E' || b == b'+' || b == b'-' {
                self.pos += 1;
            } else {
                break;
            }
        }
        let s = std::str::from_utf8(&self.bytes[start..self.pos]).ok()?;
        let n = s.parse::<f64>().ok()?;
        Some(JsonVal::Num(n))
    }

    fn parse_array(&mut self) -> Option<JsonVal> {
        self.skip_ws();
        if self.bytes.get(self.pos) != Some(&b'[') {
            return None;
        }
        self.pos += 1;
        let mut arr = Vec::new();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Some(JsonVal::Arr(arr));
        }
        loop {
            let val = self.parse_value()?;
            arr.push(val);
            match self.peek()? {
                b',' => self.pos += 1,
                b']' => {
                    self.pos += 1;
                    return Some(JsonVal::Arr(arr));
                }
                _ => return None,
            }
        }
    }

    fn parse_object(&mut self) -> Option<JsonVal> {
        self.skip_ws();
        if self.bytes.get(self.pos) != Some(&b'{') {
            return None;
        }
        self.pos += 1;
        let mut map = BTreeMap::new();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Some(JsonVal::Obj(map));
        }
        loop {
            let key = self.parse_string()?;
            if self.peek() != Some(b':') {
                return None;
            }
            self.pos += 1;
            let val = self.parse_value()?;
            map.insert(key, val);
            match self.peek()? {
                b',' => self.pos += 1,
                b'}' => {
                    self.pos += 1;
                    return Some(JsonVal::Obj(map));
                }
                _ => return None,
            }
        }
    }
}

fn parse_json(input: &str) -> Option<JsonVal> {
    let mut parser = JsonParser::new(input);
    parser.parse_value()
}

// ============================================================================
// String Normalization, Hashing & Cleaning Helpers
// ============================================================================

fn fnv1a_hex(s: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{:016x}", hash)
}

fn clean_title(t: &str) -> String {
    let trimmed = t.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let noise_words = [
        "remaster",
        "edition",
        "version",
        "deluxe",
        "exclusive",
        "live",
        "audio",
        "video",
        "official",
        "feat.",
        "feat ",
        "ft.",
        "ft ",
        "with ",
    ];
    let mut out = String::with_capacity(trimmed.len());
    let chars: Vec<char> = trimmed.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if ch == '(' || ch == '[' {
            let close = if ch == '(' { ')' } else { ']' };
            let mut end = None;
            for (j, &c) in chars.iter().enumerate().skip(i + 1) {
                if c == close {
                    end = Some(j);
                    break;
                }
            }
            if let Some(j) = end {
                let inside: String = chars[i + 1..j].iter().collect();
                let lower = inside.to_ascii_lowercase();
                if noise_words.iter().any(|w| lower.contains(w)) {
                    while out.ends_with(' ') {
                        out.pop();
                    }
                    i = j + 1;
                    continue;
                }
            }
        }
        out.push(ch);
        i += 1;
    }
    let res = out.trim().to_string();
    if res.is_empty() {
        trimmed.to_string()
    } else {
        res
    }
}

fn norm_key(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

fn extract_primary_artist(artist: &str) -> String {
    let lower = artist.to_ascii_lowercase();
    let mut cut = artist.len();
    for sep in [",", "&", " and ", " feat.", " feat ", " ft.", " ft "] {
        if let Some(idx) = lower.find(sep) {
            if idx > 0 && idx < cut {
                cut = idx;
            }
        }
    }
    artist[..cut].trim().to_string()
}

fn track_rating_key(title: &str, artist: &str) -> String {
    let t_norm = norm_key(&clean_title(title));
    if t_norm.is_empty() {
        return String::new();
    }
    let a_norm = norm_key(&extract_primary_artist(artist));
    format!("{}|{}", t_norm, a_norm)
}

fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for b in s.as_bytes() {
        match *b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char);
            }
            b' ' => out.push_str("%20"),
            other => out.push_str(&format!("%{:02X}", other)),
        }
    }
    out
}

fn url_decode_path(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex_str, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

// ============================================================================
// Filesystem & Persistent State Helpers
// ============================================================================

fn ratings_file_path() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    Path::new(&home).join(".local/share/turntable/ytm_ratings.json")
}

fn ensure_dirs() {
    let _ = fs::create_dir_all(ART_DIR);
    if let Some(parent) = ratings_file_path().parent() {
        let _ = fs::create_dir_all(parent);
    }
}

fn load_ratings() -> BTreeMap<String, String> {
    ensure_dirs();
    let path = ratings_file_path();
    let mut out = BTreeMap::new();
    if let Ok(content) = fs::read_to_string(&path) {
        if let Some(JsonVal::Obj(map)) = parse_json(&content) {
            for (k, v) in map {
                if let Some(s) = v.as_str() {
                    out.insert(k, s.to_string());
                }
            }
        }
    }
    out
}

fn save_ratings(ratings: &BTreeMap<String, String>) {
    ensure_dirs();
    let path = ratings_file_path();
    let tmp = path.with_extension("json.tmp");
    let mut obj = BTreeMap::new();
    for (k, v) in ratings {
        obj.insert(k.clone(), JsonVal::Str(v.clone()));
    }
    let json = JsonVal::Obj(obj).to_json_string();
    if fs::write(&tmp, json).is_ok() {
        let _ = fs::rename(&tmp, &path);
    }
}

fn get_track_rating(title: &str, artist: &str, ratings: &BTreeMap<String, String>) -> String {
    let key = track_rating_key(title, artist);
    if key.is_empty() {
        return "NONE".to_string();
    }
    if let Some(r) = ratings.get(&key) {
        if r == "LIKE" || r == "DISLIKE" {
            return r.clone();
        }
    }
    let t_only = format!("{}|", norm_key(&clean_title(title)));
    if let Some(r) = ratings.get(&t_only) {
        if r == "LIKE" || r == "DISLIKE" {
            return r.clone();
        }
    }
    "NONE".to_string()
}

fn set_track_rating(title: &str, artist: &str, rating: &str) -> String {
    let mut ratings = load_ratings();
    let key = track_rating_key(title, artist);
    if key.is_empty() {
        return "NONE".to_string();
    }
    let t_only = format!("{}|", norm_key(&clean_title(title)));
    let final_rating = if rating == "LIKE" || rating == "DISLIKE" {
        ratings.insert(key, rating.to_string());
        ratings.insert(t_only, rating.to_string());
        rating.to_string()
    } else {
        ratings.remove(&key);
        ratings.remove(&t_only);
        "NONE".to_string()
    };
    save_ratings(&ratings);
    final_rating
}

// ============================================================================
// Hyprland YouTube Music Window Detection & Shortcut Dispatch
// ============================================================================

struct YtmWindowInfo {
    available: bool,
    class: String,
}

fn detect_ytm_window() -> YtmWindowInfo {
    let out = Command::new("hyprctl")
        .args(["clients", "-j"])
        .output();
    if let Ok(res) = out {
        if res.status.success() {
            if let Ok(stdout) = String::from_utf8(res.stdout) {
                if let Some(JsonVal::Arr(clients)) = parse_json(&stdout) {
                    for c in clients {
                        let cls = c.get_str("class");
                        let init_cls = c.get_str("initialClass");
                        let title = c.get_str("title");
                        if cls.contains("music.youtube.com")
                            || init_cls.contains("music.youtube.com")
                            || title.contains("YouTube Music")
                        {
                            let chosen = if !cls.is_empty() { cls } else { init_cls };
                            return YtmWindowInfo {
                                available: true,
                                class: chosen.to_string(),
                            };
                        }
                    }
                }
            }
        }
    }
    YtmWindowInfo {
        available: false,
        class: String::new(),
    }
}

fn regex_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for ch in s.chars() {
        if matches!(
            ch,
            '.' | '+' | '*' | '?' | '^' | '$' | '(' | ')' | '[' | ']' | '{' | '}' | '|' | '\\'
        ) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

fn send_ytm_shortcut(mods: &str, key: &str) -> bool {
    let info = detect_ytm_window();
    let target_regex = if info.available && !info.class.is_empty() {
        format!("class:^({})$", regex_escape(&info.class))
    } else {
        "class:^(chrome-music\\.youtube\\.com.*)$".to_string()
    };
    let lua_escaped_regex = target_regex.replace('\\', "\\\\");
    let lua_expr = format!(
        "hl.dispatch(hl.dsp.send_shortcut({{ mods = \"{}\", key = \"{}\", window = \"{}\" }}))",
        mods, key, lua_escaped_regex
    );
    if let Ok(res) = Command::new("hyprctl").args(["eval", &lua_expr]).output() {
        if res.status.success() {
            let stdout = String::from_utf8_lossy(&res.stdout);
            return stdout.contains("ok");
        }
    }
    false
}

fn handle_action(action: &str, title: &str, artist: &str) -> JsonVal {
    let act = action.trim().to_ascii_lowercase();
    let ratings = load_ratings();
    let cur_rating = get_track_rating(title, artist, &ratings);
    let mut map = BTreeMap::new();

    match act.as_str() {
        "like" => {
            let new_rating = if cur_rating == "LIKE" { "NONE" } else { "LIKE" };
            let saved = set_track_rating(title, artist, new_rating);
            let dispatched = send_ytm_shortcut("SHIFT", "equal");
            map.insert("ok".to_string(), JsonVal::Bool(true));
            map.insert("action".to_string(), JsonVal::Str("like".to_string()));
            map.insert("rating".to_string(), JsonVal::Str(saved));
            map.insert("dispatched".to_string(), JsonVal::Bool(dispatched));
            map.insert("title".to_string(), JsonVal::Str(title.to_string()));
            map.insert("artist".to_string(), JsonVal::Str(artist.to_string()));
        }
        "dislike" => {
            let new_rating = if cur_rating == "DISLIKE" { "NONE" } else { "DISLIKE" };
            let saved = set_track_rating(title, artist, new_rating);
            let dispatched = send_ytm_shortcut("SHIFT", "minus");
            map.insert("ok".to_string(), JsonVal::Bool(true));
            map.insert("action".to_string(), JsonVal::Str("dislike".to_string()));
            map.insert("rating".to_string(), JsonVal::Str(saved));
            map.insert("dispatched".to_string(), JsonVal::Bool(dispatched));
            map.insert("title".to_string(), JsonVal::Str(title.to_string()));
            map.insert("artist".to_string(), JsonVal::Str(artist.to_string()));
        }
        "shuffle" => {
            let dispatched = send_ytm_shortcut("", "s");
            map.insert("ok".to_string(), JsonVal::Bool(true));
            map.insert("action".to_string(), JsonVal::Str("shuffle".to_string()));
            map.insert("dispatched".to_string(), JsonVal::Bool(dispatched));
        }
        "repeat" => {
            let dispatched = send_ytm_shortcut("", "r");
            map.insert("ok".to_string(), JsonVal::Bool(true));
            map.insert("action".to_string(), JsonVal::Str("repeat".to_string()));
            map.insert("dispatched".to_string(), JsonVal::Bool(dispatched));
        }
        "seek-forward" => {
            let dispatched = send_ytm_shortcut("", "l");
            map.insert("ok".to_string(), JsonVal::Bool(true));
            map.insert("action".to_string(), JsonVal::Str("seek-forward".to_string()));
            map.insert("dispatched".to_string(), JsonVal::Bool(dispatched));
        }
        "seek-backward" => {
            let dispatched = send_ytm_shortcut("", "h");
            map.insert("ok".to_string(), JsonVal::Bool(true));
            map.insert("action".to_string(), JsonVal::Str("seek-backward".to_string()));
            map.insert("dispatched".to_string(), JsonVal::Bool(dispatched));
        }
        "open-ytm" => {
            let ok = Command::new("omarchy-launch-webapp")
                .arg("https://music.youtube.com/")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .is_ok();
            map.insert("ok".to_string(), JsonVal::Bool(ok));
            map.insert("action".to_string(), JsonVal::Str("open-ytm".to_string()));
        }
        _ => {
            map.insert("ok".to_string(), JsonVal::Bool(false));
            map.insert("action".to_string(), JsonVal::Str(act));
            map.insert("rating".to_string(), JsonVal::Str(cur_rating));
        }
    }
    JsonVal::Obj(map)
}

// ============================================================================
// High-Res Cover Art Caching & iTunes Catalog Resolution
// ============================================================================

fn cache_local_mpris_art(art_url: &str, title: &str, artist: &str) -> String {
    ensure_dirs();
    let hash = fnv1a_hex(&format!("{}|{}", norm_key(title), norm_key(artist)));
    let dst = Path::new(ART_DIR).join(format!("local_{}.img", hash));

    if let Some(stripped) = art_url.strip_prefix("file://") {
        let src_path = url_decode_path(stripped);
        if let Ok(meta) = fs::metadata(&src_path) {
            if meta.is_file() && meta.len() > 0 {
                let _ = fs::copy(&src_path, &dst);
                return format!("file://{}", dst.display());
            }
        }
        if let Ok(meta) = fs::metadata(&dst) {
            if meta.is_file() && meta.len() > 0 {
                return format!("file://{}", dst.display());
            }
        }
        return String::new();
    }

    if let Ok(meta) = fs::metadata(&dst) {
        if meta.is_file() && meta.len() > 0 {
            return format!("file://{}", dst.display());
        }
    }
    art_url.to_string()
}

fn cache_remote_art_url(remote_url: &str) -> String {
    if remote_url.is_empty() || remote_url.starts_with("file://") {
        return remote_url.to_string();
    }
    ensure_dirs();
    let hash = fnv1a_hex(remote_url);
    let dst = Path::new(ART_DIR).join(format!("art_{}.jpg", hash));
    if let Ok(meta) = fs::metadata(&dst) {
        if meta.is_file() && meta.len() > 256 {
            return format!("file://{}", dst.display());
        }
    }
    let tmp = dst.with_extension("jpg.tmp");
    let status = Command::new("curl")
        .args([
            "-fsSL",
            "--max-time",
            "2.5",
            "-A",
            "Turntable/1.0",
            "-o",
        ])
        .arg(&tmp)
        .arg(remote_url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if let Ok(st) = status {
        if st.success() {
            if let Ok(meta) = fs::metadata(&tmp) {
                if meta.len() > 256 && fs::rename(&tmp, &dst).is_ok() {
                    return format!("file://{}", dst.display());
                }
            }
        }
    }
    let _ = fs::remove_file(&tmp);
    remote_url.to_string()
}

fn fetch_json_url(url: &str) -> Option<JsonVal> {
    let out = Command::new("curl")
        .args(["-fsSL", "--max-time", "3.0", "-A", "Turntable/1.0", url])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8(out.stdout).ok()?;
    parse_json(&text)
}

fn post_json_raw(url: &str, body: &str) -> Option<String> {
    let out = Command::new("curl")
        .args([
            "-fsSL",
            "--max-time",
            "3.0",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-A",
            "Mozilla/5.0",
            "-d",
            body,
            url,
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout).ok()
}

fn find_first_video_id(raw: &str) -> Option<String> {
    let needle = "\"videoId\":\"";
    let mut rest = raw;
    while let Some(idx) = rest.find(needle) {
        let after = &rest[idx + needle.len()..];
        if let Some(end) = after.find('"') {
            let candidate = &after[..end];
            if candidate.len() == 11
                && candidate
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
            {
                return Some(candidate.to_string());
            }
        }
        rest = after;
    }
    None
}

fn parse_mmss_duration(s: &str) -> f64 {
    let parts: Vec<&str> = s.trim().split(':').collect();
    if parts.len() == 2 {
        let m = parts[0].parse::<f64>().unwrap_or(0.0);
        let sec = parts[1].parse::<f64>().unwrap_or(0.0);
        return m * 60.0 + sec;
    } else if parts.len() == 3 {
        let h = parts[0].parse::<f64>().unwrap_or(0.0);
        let m = parts[1].parse::<f64>().unwrap_or(0.0);
        let sec = parts[2].parse::<f64>().unwrap_or(0.0);
        return h * 3600.0 + m * 60.0 + sec;
    }
    0.0
}

fn format_ytm_panel_renderer(r: &JsonVal) -> Option<JsonVal> {
    let title = r
        .get("title")?
        .get("runs")?
        .as_arr()?
        .first()?
        .get_str("text")
        .to_string();
    if title.is_empty() {
        return None;
    }

    let mut artist = String::new();
    if let Some(runs) = r
        .get("shortBylineText")
        .and_then(|v| v.get("runs"))
        .and_then(|v| v.as_arr())
    {
        for run in runs {
            artist.push_str(run.get_str("text"));
        }
    }

    let mut album = String::new();
    if let Some(runs) = r
        .get("longBylineText")
        .and_then(|v| v.get("runs"))
        .and_then(|v| v.as_arr())
    {
        if artist.is_empty() {
            if let Some(first) = runs.first() {
                artist = first.get_str("text").to_string();
            }
        }
        for run in runs {
            let page_type = run
                .get("navigationEndpoint")
                .and_then(|v| v.get("browseEndpoint"))
                .and_then(|v| v.get("browseEndpointContextSupportedConfigs"))
                .and_then(|v| v.get("browseEndpointContextMusicConfig"))
                .map(|v| v.get_str("pageType"))
                .unwrap_or("");
            if page_type == "MUSIC_PAGE_TYPE_ALBUM" {
                album = run.get_str("text").to_string();
                break;
            }
        }
    }

    let mut art_url = String::new();
    if let Some(thumbs) = r
        .get("thumbnail")
        .and_then(|v| v.get("thumbnails"))
        .and_then(|v| v.as_arr())
    {
        if let Some(last) = thumbs.last() {
            art_url = last.get_str("url").to_string();
        }
    }

    let dur_str = r
        .get("lengthText")
        .and_then(|v| v.get("runs"))
        .and_then(|v| v.as_arr())
        .and_then(|a| a.first())
        .map(|v| v.get_str("text"))
        .unwrap_or("");
    let duration = parse_mmss_duration(dur_str);

    let mut m = BTreeMap::new();
    m.insert("title".to_string(), JsonVal::Str(title));
    m.insert("artist".to_string(), JsonVal::Str(artist));
    m.insert("album".to_string(), JsonVal::Str(album));
    m.insert("artUrl".to_string(), JsonVal::Str(art_url));
    m.insert("trackNumber".to_string(), JsonVal::Num(0.0));
    m.insert("discNumber".to_string(), JsonVal::Num(1.0));
    m.insert("duration".to_string(), JsonVal::Num(duration));
    Some(JsonVal::Obj(m))
}

fn fetch_ytm_radio_queue(title: &str, artist: &str) -> Vec<JsonVal> {
    let q = format!("{} {}", clean_title(title), extract_primary_artist(artist))
        .trim()
        .to_string();
    if q.is_empty() {
        return Vec::new();
    }

    let mut escaped_q = String::new();
    JsonVal::Str(q).write_json(&mut escaped_q);

    let search_body = format!(
        "{{\"context\":{{\"client\":{{\"clientName\":\"WEB_REMIX\",\"clientVersion\":\"1.20260101.01.00\",\"hl\":\"en\",\"gl\":\"US\"}}}},\"query\":{},\"params\":\"EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D\"}}",
        escaped_q
    );
    let search_raw = match post_json_raw(
        "https://music.youtube.com/youtubei/v1/search?prettyPrint=false",
        &search_body,
    ) {
        Some(s) => s,
        None => return Vec::new(),
    };

    let vid = match find_first_video_id(&search_raw) {
        Some(v) => v,
        None => return Vec::new(),
    };

    let next_body = format!(
        "{{\"context\":{{\"client\":{{\"clientName\":\"WEB_REMIX\",\"clientVersion\":\"1.20260101.01.00\",\"hl\":\"en\",\"gl\":\"US\"}}}},\"videoId\":\"{}\",\"playlistId\":\"RDAMVM{}\",\"isAudioOnly\":true}}",
        vid, vid
    );
    let next_raw = match post_json_raw(
        "https://music.youtube.com/youtubei/v1/next?prettyPrint=false",
        &next_body,
    ) {
        Some(s) => s,
        None => return Vec::new(),
    };

    let parsed = match parse_json(&next_raw) {
        Some(p) => p,
        None => return Vec::new(),
    };

    let contents = parsed
        .get("contents")
        .and_then(|v| v.get("singleColumnMusicWatchNextResultsRenderer"))
        .and_then(|v| v.get("tabbedRenderer"))
        .and_then(|v| v.get("watchNextTabbedResultsRenderer"))
        .and_then(|v| v.get("tabs"))
        .and_then(|v| v.as_arr())
        .and_then(|a| a.first())
        .and_then(|v| v.get("tabRenderer"))
        .and_then(|v| v.get("content"))
        .and_then(|v| v.get("musicQueueRenderer"))
        .and_then(|v| v.get("content"))
        .and_then(|v| v.get("playlistPanelRenderer"))
        .and_then(|v| v.get("contents"))
        .and_then(|v| v.as_arr());

    let mut out = Vec::new();
    if let Some(items) = contents {
        for item in items.iter().take(24) {
            if let Some(r) = item.get("playlistPanelVideoRenderer") {
                if let Some(ft) = format_ytm_panel_renderer(r) {
                    out.push(ft);
                }
            }
        }
    }
    out
}

fn format_itunes_track(r: &JsonVal) -> JsonVal {
    let mut art = r.get_str("artworkUrl100").to_string();
    if art.is_empty() {
        art = r.get_str("artworkUrl60").to_string();
    }
    if !art.is_empty() {
        // Request sharp 600x600 high-DPI album art from Apple CDN
        art = art
            .replace("100x100bb", "600x600bb")
            .replace("60x60bb", "600x600bb");
    }
    let duration_sec = ((r.get_f64("trackTimeMillis", 0.0) / 100.0).round()) / 10.0;
    let mut m = BTreeMap::new();
    m.insert("title".to_string(), JsonVal::Str(r.get_str("trackName").to_string()));
    m.insert("artist".to_string(), JsonVal::Str(r.get_str("artistName").to_string()));
    m.insert(
        "album".to_string(),
        JsonVal::Str(r.get_str("collectionName").to_string()),
    );
    m.insert("artUrl".to_string(), JsonVal::Str(art));
    m.insert(
        "trackNumber".to_string(),
        JsonVal::Num(r.get_i64("trackNumber", 0) as f64),
    );
    m.insert(
        "discNumber".to_string(),
        JsonVal::Num(r.get_i64("discNumber", 1) as f64),
    );
    m.insert("duration".to_string(), JsonVal::Num(duration_sec));
    JsonVal::Obj(m)
}

fn load_catalog_cache() -> BTreeMap<String, JsonVal> {
    if let Ok(content) = fs::read_to_string(CATALOG_FILE) {
        if let Some(JsonVal::Obj(map)) = parse_json(&content) {
            return map;
        }
    }
    BTreeMap::new()
}

fn save_catalog_cache(cache: BTreeMap<String, JsonVal>) {
    ensure_dirs();
    let tmp = format!("{}.tmp", CATALOG_FILE);
    let json = JsonVal::Obj(cache).to_json_string();
    if fs::write(&tmp, json).is_ok() {
        let _ = fs::rename(&tmp, CATALOG_FILE);
    }
}

fn query_tracks(title: &str, artist: &str, album: &str) -> (Vec<JsonVal>, Vec<JsonVal>) {
    ensure_dirs();
    let mut cache = load_catalog_cache();
    let cache_key = format!("ytm_v2|{}|{}|{}", norm_key(title), norm_key(artist), norm_key(album));
    if let Some(cached) = cache.get(&cache_key) {
        let alb = cached
            .get("albumTracks")
            .and_then(|v| v.as_arr())
            .cloned()
            .unwrap_or_default();
        let art = cached
            .get("artistTracks")
            .and_then(|v| v.as_arr())
            .cloned()
            .unwrap_or_default();
        if !alb.is_empty() || !art.is_empty() {
            return (alb, art);
        }
    }

    // 1. Primary: Query YouTube Music's live Automix / Up Next Queue (RDAMVM)
    let ytm_queue = fetch_ytm_radio_queue(title, artist);
    if ytm_queue.len() >= 4 {
        let mut entry = BTreeMap::new();
        entry.insert("albumTracks".to_string(), JsonVal::Arr(Vec::new()));
        entry.insert("artistTracks".to_string(), JsonVal::Arr(ytm_queue.clone()));
        cache.insert(cache_key, JsonVal::Obj(entry));
        save_catalog_cache(cache);
        return (Vec::new(), ytm_queue);
    }

    let title_clean = clean_title(title);
    let primary_artist = extract_primary_artist(artist);
    let eff_artist = if !primary_artist.is_empty() {
        primary_artist.as_str()
    } else {
        artist
    };

    let mut album_tracks = Vec::new();
    let mut artist_tracks = Vec::new();

    let q_str = format!("{} {}", title_clean, eff_artist).trim().to_string();
    if !q_str.is_empty() {
        let search_url = format!(
            "https://itunes.apple.com/search?term={}&entity=song&limit=12",
            url_encode(&q_str)
        );
        if let Some(resp) = fetch_json_url(&search_url) {
            if let Some(results) = resp.get("results").and_then(|v| v.as_arr()) {
                let target_norm = norm_key(&title_clean);
                let mut collection_id: Option<i64> = None;
                for r in results {
                    let r_norm = norm_key(&clean_title(r.get_str("trackName")));
                    let cid = r.get_i64("collectionId", 0);
                    if r_norm == target_norm && cid > 0 {
                        collection_id = Some(cid);
                        break;
                    }
                }
                if collection_id.is_none() {
                    if let Some(first) = results.first() {
                        let cid = first.get_i64("collectionId", 0);
                        if cid > 0 {
                            collection_id = Some(cid);
                        }
                    }
                }

                if let Some(cid) = collection_id {
                    let lookup_url = format!(
                        "https://itunes.apple.com/lookup?id={}&entity=song&limit=60",
                        cid
                    );
                    if let Some(lresp) = fetch_json_url(&lookup_url) {
                        if let Some(lres) = lresp.get("results").and_then(|v| v.as_arr()) {
                            let mut raw_tracks: Vec<&JsonVal> = lres
                                .iter()
                                .filter(|x| x.get_str("wrapperType") == "track")
                                .collect();
                            raw_tracks.sort_by_key(|x| {
                                (x.get_i64("discNumber", 1), x.get_i64("trackNumber", 0))
                            });
                            for rt in raw_tracks {
                                let ft = format_itunes_track(rt);
                                if !ft.get_str("title").is_empty() {
                                    album_tracks.push(ft);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    let aq_str = if !eff_artist.is_empty() {
        eff_artist
    } else {
        title_clean.as_str()
    };
    if !aq_str.is_empty() {
        let aurl = format!(
            "https://itunes.apple.com/search?term={}&entity=song&limit=35",
            url_encode(aq_str)
        );
        if let Some(aresp) = fetch_json_url(&aurl) {
            if let Some(ares) = aresp.get("results").and_then(|v| v.as_arr()) {
                let mut seen = HashSet::new();
                for r in ares {
                    let ft = format_itunes_track(r);
                    let nk = norm_key(&clean_title(ft.get_str("title")));
                    if !nk.is_empty() && seen.insert(nk) {
                        artist_tracks.push(ft);
                    }
                }
            }
        }
    }

    if !album_tracks.is_empty() || !artist_tracks.is_empty() {
        let mut entry = BTreeMap::new();
        entry.insert("albumTracks".to_string(), JsonVal::Arr(album_tracks.clone()));
        entry.insert(
            "artistTracks".to_string(),
            JsonVal::Arr(artist_tracks.clone()),
        );
        cache.insert(cache_key, JsonVal::Obj(entry));
        save_catalog_cache(cache);
    }

    (album_tracks, artist_tracks)
}

fn enrich_track(
    t: &JsonVal,
    fallback_artist: &str,
    ratings: &BTreeMap<String, String>,
) -> JsonVal {
    let mut m = t.as_obj().cloned().unwrap_or_default();
    let cleaned = clean_title(t.get_str("title"));
    let tr_artist = {
        let a = t.get_str("artist");
        if a.is_empty() {
            fallback_artist.to_string()
        } else {
            a.to_string()
        }
    };
    let rating = get_track_rating(&cleaned, &tr_artist, ratings);
    m.insert("title".to_string(), JsonVal::Str(cleaned));
    m.insert("rating".to_string(), JsonVal::Str(rating));
    JsonVal::Obj(m)
}

fn build_queue(title: &str, artist: &str, album: &str, art_url: &str) -> JsonVal {
    let ratings = load_ratings();
    let ytm_info = detect_ytm_window();
    let cached_mpris_art = cache_local_mpris_art(art_url, title, artist);
    let (album_tracks, artist_tracks) = query_tracks(title, artist, album);

    let target_norm = norm_key(&clean_title(title));
    let mut current_idx: Option<usize> = None;
    for (i, t) in album_tracks.iter().enumerate() {
        let tn = norm_key(&clean_title(t.get_str("title")));
        if !tn.is_empty()
            && (tn == target_norm
                || (!target_norm.is_empty() && (target_norm.contains(&tn) || tn.contains(&target_norm))))
        {
            current_idx = Some(i);
            break;
        }
    }

    let mut prev_list: Vec<JsonVal> = Vec::new();
    let mut next_list: Vec<JsonVal> = Vec::new();
    let mut used_norms: HashSet<String> = HashSet::new();
    if !target_norm.is_empty() {
        used_norms.insert(target_norm.clone());
    }

    if let Some(cidx) = current_idx {
        let start_prev = cidx.saturating_sub(5);
        for i in (start_prev..cidx).rev() {
            let tc = enrich_track(&album_tracks[i], artist, &ratings);
            let nk = norm_key(tc.get_str("title"));
            if nk.len() > 1 && used_norms.insert(nk) {
                prev_list.push(tc);
            }
        }
        let end_next = (cidx + 6).min(album_tracks.len());
        for i in (cidx + 1)..end_next {
            let tc = enrich_track(&album_tracks[i], artist, &ratings);
            let nk = norm_key(tc.get_str("title"));
            if nk.len() > 1 && used_norms.insert(nk) {
                next_list.push(tc);
            }
        }
    }

    for t in artist_tracks.iter().chain(album_tracks.iter()) {
        if prev_list.len() >= 5 && next_list.len() >= 5 {
            break;
        }
        let tc = enrich_track(t, artist, &ratings);
        let nk = norm_key(tc.get_str("title"));
        if nk.len() <= 1
            || (!target_norm.is_empty() && (nk.contains(&target_norm) || target_norm.contains(&nk)))
            || !used_norms.insert(nk)
        {
            continue;
        }
        if next_list.len() < 5 {
            next_list.push(tc);
        } else if prev_list.len() < 5 {
            prev_list.push(tc);
        }
    }

    let mut remote_art = String::new();
    let mut current_duration = 0.0f64;
    if let Some(cidx) = current_idx {
        remote_art = album_tracks[cidx].get_str("artUrl").to_string();
        current_duration = album_tracks[cidx].get_f64("duration", 0.0);
    }
    if remote_art.is_empty() {
        for t in &artist_tracks {
            let tn = norm_key(&clean_title(t.get_str("title")));
            if !tn.is_empty() && (tn == target_norm || target_norm.contains(&tn) || tn.contains(&target_norm)) {
                remote_art = t.get_str("artUrl").to_string();
                current_duration = t.get_f64("duration", 0.0);
                break;
            }
        }
    }
    if remote_art.is_empty() {
        if let Some(first) = artist_tracks.first() {
            remote_art = first.get_str("artUrl").to_string();
            if current_duration <= 0.0 {
                current_duration = first.get_f64("duration", 0.0);
            }
        }
    }

    // Download & cache high-res remote artwork locally in parallel threads so Qt Quick
    // renders local 600x600 files with zero network lag or progressive blur!
    let mut urls_to_cache: Vec<String> = Vec::new();
    if !remote_art.is_empty() {
        urls_to_cache.push(remote_art.clone());
    }
    for item in prev_list.iter().chain(next_list.iter()) {
        let u = item.get_str("artUrl").to_string();
        if !u.is_empty() && !urls_to_cache.contains(&u) {
            urls_to_cache.push(u);
        }
    }

    let mut resolved_art_map: BTreeMap<String, String> = BTreeMap::new();
    thread::scope(|s| {
        let handles: Vec<_> = urls_to_cache
            .iter()
            .map(|u| {
                let url_clone = u.clone();
                s.spawn(move || {
                    let cached = cache_remote_art_url(&url_clone);
                    (url_clone, cached)
                })
            })
            .collect();
        for h in handles {
            if let Ok((orig, local)) = h.join() {
                resolved_art_map.insert(orig, local);
            }
        }
    });

    let cached_remote_art = resolved_art_map
        .get(&remote_art)
        .cloned()
        .unwrap_or_else(|| remote_art.clone());

    // Prefer high-res 600x600 cached artwork when available so center vinyl art is ultra-sharp
    let effective_current_art = if cached_remote_art.starts_with("file://") {
        cached_remote_art.clone()
    } else if !cached_mpris_art.is_empty() {
        cached_mpris_art
    } else {
        cached_remote_art.clone()
    };

    for item in prev_list.iter_mut().chain(next_list.iter_mut()) {
        let orig = item.get_str("artUrl").to_string();
        let resolved = resolved_art_map.get(&orig).cloned().unwrap_or(orig);
        if let Some(obj) = item.as_obj_mut() {
            obj.insert(
                "artUrl".to_string(),
                JsonVal::Str(if resolved.is_empty() {
                    effective_current_art.clone()
                } else {
                    resolved
                }),
            );
        }
    }

    while prev_list.len() < 5 {
        let idx = prev_list.len() + 1;
        let mut m = BTreeMap::new();
        m.insert(
            "title".to_string(),
            JsonVal::Str(format!("Previous Track {}", idx)),
        );
        m.insert(
            "artist".to_string(),
            JsonVal::Str(if artist.is_empty() {
                "Unknown Artist".to_string()
            } else {
                artist.to_string()
            }),
        );
        m.insert("album".to_string(), JsonVal::Str(album.to_string()));
        m.insert(
            "artUrl".to_string(),
            JsonVal::Str(effective_current_art.clone()),
        );
        m.insert("trackNumber".to_string(), JsonVal::Num(0.0));
        m.insert("duration".to_string(), JsonVal::Num(0.0));
        m.insert("rating".to_string(), JsonVal::Str("NONE".to_string()));
        prev_list.push(JsonVal::Obj(m));
    }

    while next_list.len() < 5 {
        let idx = next_list.len() + 1;
        let mut m = BTreeMap::new();
        m.insert(
            "title".to_string(),
            JsonVal::Str(format!("Up Next Track {}", idx)),
        );
        m.insert(
            "artist".to_string(),
            JsonVal::Str(if artist.is_empty() {
                "Unknown Artist".to_string()
            } else {
                artist.to_string()
            }),
        );
        m.insert("album".to_string(), JsonVal::Str(album.to_string()));
        m.insert(
            "artUrl".to_string(),
            JsonVal::Str(effective_current_art.clone()),
        );
        m.insert("trackNumber".to_string(), JsonVal::Num(0.0));
        m.insert("duration".to_string(), JsonVal::Num(0.0));
        m.insert("rating".to_string(), JsonVal::Str("NONE".to_string()));
        next_list.push(JsonVal::Obj(m));
    }

    prev_list.truncate(5);
    next_list.truncate(5);

    let cur_rating = get_track_rating(title, artist, &ratings);
    let mut current_item = BTreeMap::new();
    current_item.insert(
        "title".to_string(),
        JsonVal::Str(if title.is_empty() {
            "Nothing playing".to_string()
        } else {
            title.to_string()
        }),
    );
    current_item.insert("artist".to_string(), JsonVal::Str(artist.to_string()));
    current_item.insert("album".to_string(), JsonVal::Str(album.to_string()));
    current_item.insert("artUrl".to_string(), JsonVal::Str(effective_current_art));
    current_item.insert("remoteArtUrl".to_string(), JsonVal::Str(cached_remote_art));
    current_item.insert("duration".to_string(), JsonVal::Num(current_duration));
    current_item.insert("rating".to_string(), JsonVal::Str(cur_rating));

    let mut out = BTreeMap::new();
    out.insert("ytmAvailable".to_string(), JsonVal::Bool(ytm_info.available));
    out.insert("ytmWindowClass".to_string(), JsonVal::Str(ytm_info.class));
    out.insert("current".to_string(), JsonVal::Obj(current_item));
    out.insert("previous".to_string(), JsonVal::Arr(prev_list));
    out.insert("next".to_string(), JsonVal::Arr(next_list));
    JsonVal::Obj(out)
}

// ============================================================================
// Real-Time PipeWire / PulseAudio FFT Spectrum Streamer (--spectrum)
// ============================================================================

fn fft_in_place(re: &mut [f32], im: &mut [f32]) {
    let n = re.len();
    let mut j = 0usize;
    for i in 1..n {
        let mut bit = n >> 1;
        while (j & bit) != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }

    let mut len = 2usize;
    while len <= n {
        let half = len >> 1;
        let ang = -2.0 * std::f32::consts::PI / (len as f32);
        let wlen_re = ang.cos();
        let wlen_im = ang.sin();
        let mut i = 0usize;
        while i < n {
            let mut w_re = 1.0f32;
            let mut w_im = 0.0f32;
            for k in 0..half {
                let u_re = re[i + k];
                let u_im = im[i + k];
                let v_re = re[i + k + half] * w_re - im[i + k + half] * w_im;
                let v_im = re[i + k + half] * w_im + im[i + k + half] * w_re;
                re[i + k] = u_re + v_re;
                im[i + k] = u_im + v_im;
                re[i + k + half] = u_re - v_re;
                im[i + k + half] = u_im - v_im;
                let next_w_re = w_re * wlen_re - w_im * wlen_im;
                w_im = w_re * wlen_im + w_im * wlen_re;
                w_re = next_w_re;
            }
            i += len;
        }
        len <<= 1;
    }
}

fn run_spectrum_streamer() {
    use std::io::{Read, Write};
    use std::time::Duration;

    const FFT_SIZE: usize = 2048;
    const HOP_SAMPLES: usize = 735; // ~30 FPS at 22,050 Hz
    const NUM_BANDS: usize = 48;
    const SAMPLE_RATE: f32 = 22050.0;

    let mut hann = [0.0f32; FFT_SIZE];
    for i in 0..FFT_SIZE {
        hann[i] = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * (i as f32) / ((FFT_SIZE - 1) as f32)).cos());
    }

    // Precompute fractional logarithmic frequency bin ranges for 48 bands (45 Hz .. 9800 Hz)
    let min_freq = 45.0f32;
    let max_freq = 9800.0f32;
    let mut band_specs: Vec<(f32, f32, f32)> = Vec::with_capacity(NUM_BANDS);
    for b in 0..NUM_BANDS {
        let t0 = (b as f32) / (NUM_BANDS as f32);
        let t1 = ((b + 1) as f32) / (NUM_BANDS as f32);
        let f0 = min_freq * (max_freq / min_freq).powf(t0);
        let f1 = min_freq * (max_freq / min_freq).powf(t1);
        let bin0 = (f0 * (FFT_SIZE as f32) / SAMPLE_RATE).clamp(1.0, (FFT_SIZE / 2 - 2) as f32);
        let bin1 = (f1 * (FFT_SIZE as f32) / SAMPLE_RATE).clamp(bin0, (FFT_SIZE / 2 - 1) as f32);
        let center_f = 0.5 * (f0 + f1);
        // Equal-loudness / pink-noise tilt so mids and treble dance as vibrantly as bass
        let tilt = (center_f / 95.0).powf(0.56).clamp(0.70, 6.5);
        band_specs.push((bin0, bin1, tilt));
    }

    let mut ring = [0.0f32; FFT_SIZE];
    let mut re = [0.0f32; FFT_SIZE];
    let mut im = [0.0f32; FFT_SIZE];
    let mut mag_bins = [0.0f32; FFT_SIZE / 2];
    let mut smooth_bands = [0.10f32; NUM_BANDS];
    let mut peaks = [0.14f32; NUM_BANDS];
    let mut agc_ref = 0.08f32;

    loop {
        let child = Command::new("parec")
            .args([
                "-d",
                "@DEFAULT_MONITOR@",
                "--raw",
                "--format=s16le",
                "--rate=22050",
                "--channels=1",
                "--latency-msec=22",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();

        let mut child = match child {
            Ok(c) => c,
            Err(_) => {
                std::thread::sleep(Duration::from_millis(500));
                continue;
            }
        };

        if let Some(mut stdout) = child.stdout.take() {
            let mut pcm_bytes = vec![0u8; HOP_SAMPLES * 2];
            loop {
                let mut read_total = 0usize;
                while read_total < pcm_bytes.len() {
                    match stdout.read(&mut pcm_bytes[read_total..]) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => read_total += n,
                    }
                }
                if read_total < pcm_bytes.len() {
                    break;
                }

                // Shift ring buffer by HOP_SAMPLES and append new normalized samples
                ring.copy_within(HOP_SAMPLES..FFT_SIZE, 0);
                for s in 0..HOP_SAMPLES {
                    let lo = pcm_bytes[s * 2];
                    let hi = pcm_bytes[s * 2 + 1];
                    let sample = i16::from_le_bytes([lo, hi]) as f32 / 32768.0;
                    ring[FFT_SIZE - HOP_SAMPLES + s] = sample;
                }

                for i in 0..FFT_SIZE {
                    re[i] = ring[i] * hann[i];
                    im[i] = 0.0;
                }

                fft_in_place(&mut re, &mut im);

                let norm_scale = 1.0 / (FFT_SIZE as f32 * 0.22);
                for k in 0..(FFT_SIZE / 2) {
                    mag_bins[k] = (re[k] * re[k] + im[k] * im[k]).sqrt() * norm_scale;
                }

                let mut raw_bands = [0.0f32; NUM_BANDS];
                let mut frame_max = 0.001f32;

                for (b, &(bin0, bin1, tilt)) in band_specs.iter().enumerate() {
                    let avg = if (bin1 - bin0) < 1.25 {
                        // Fractional linear interpolation between adjacent FFT bins for smooth sub-bass/bass
                        let mid = 0.5 * (bin0 + bin1);
                        let k0 = (mid.floor() as usize).min(FFT_SIZE / 2 - 2);
                        let frac = mid - (k0 as f32);
                        (mag_bins[k0] * (1.0 - frac) + mag_bins[k0 + 1] * frac) * tilt
                    } else {
                        let k0 = (bin0.floor() as usize).max(1).min(FFT_SIZE / 2 - 1);
                        let k1 = (bin1.ceil() as usize).max(k0).min(FFT_SIZE / 2 - 1);
                        let mut sum = 0.0f32;
                        let mut peak_bin = 0.0f32;
                        for &m in &mag_bins[k0..=k1] {
                            sum += m;
                            if m > peak_bin {
                                peak_bin = m;
                            }
                        }
                        let mean = sum / ((k1 - k0 + 1) as f32);
                        (mean * 0.55 + peak_bin * 0.45) * tilt
                    };
                    let val = avg.powf(0.54);
                    raw_bands[b] = val;
                    if val > frame_max {
                        frame_max = val;
                    }
                }

                // Adaptive AGC reference so quiet & loud tracks both fill the spectrum nicely
                if frame_max > agc_ref {
                    agc_ref = agc_ref * 0.82 + frame_max * 0.18;
                } else {
                    agc_ref = (agc_ref * 0.985 + frame_max * 0.015).max(0.025);
                }

                // Slight neighbor smoothing + fast attack / smooth release
                let mut out_line = String::with_capacity(640);
                out_line.push_str("{\"b\":[");
                for b in 0..NUM_BANDS {
                    let prev_b = if b > 0 { raw_bands[b - 1] } else { raw_bands[b] };
                    let next_b = if b + 1 < NUM_BANDS { raw_bands[b + 1] } else { raw_bands[b] };
                    let blended = raw_bands[b] * 0.60 + (prev_b + next_b) * 0.20;

                    // Subtle bell-curve stage envelope so edges taper gracefully
                    let center_dist = ((b as f32 - (NUM_BANDS as f32 - 1.0) * 0.5) / (NUM_BANDS as f32 * 0.5)).abs();
                    let env = (1.0 - center_dist * 0.25).clamp(0.68, 1.0);

                    let norm = ((blended / (agc_ref * 1.05)) * env).clamp(0.08, 0.98);
                    let cur = smooth_bands[b];
                    let next_val = if norm > cur {
                        cur * 0.30 + norm * 0.70 // Fast attack on beats
                    } else {
                        (cur * 0.68 + norm * 0.32).max(0.08) // Smooth decay
                    };
                    smooth_bands[b] = next_val;

                    if next_val >= peaks[b] {
                        peaks[b] = next_val;
                    } else {
                        peaks[b] = (peaks[b] - 0.024).max(next_val).max(0.11);
                    }

                    if b > 0 {
                        out_line.push(',');
                    }
                    out_line.push_str(&format!("{:.3}", next_val));
                }
                out_line.push_str("],\"p\":[");
                for b in 0..NUM_BANDS {
                    if b > 0 {
                        out_line.push(',');
                    }
                    out_line.push_str(&format!("{:.3}", peaks[b]));
                }
                out_line.push_str("]}\n");

                let mut stdout_lock = std::io::stdout().lock();
                if stdout_lock.write_all(out_line.as_bytes()).is_err() || stdout_lock.flush().is_err() {
                    let _ = child.kill();
                    return;
                }
            }
        }

        let _ = child.kill();
        let _ = child.wait();
        std::thread::sleep(Duration::from_millis(300));
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut title = String::new();
    let mut artist = String::new();
    let mut album = String::new();
    let mut art = String::new();
    let mut action = String::new();
    let mut spectrum_mode = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--spectrum" => {
                spectrum_mode = true;
                i += 1;
            }
            "--title" if i + 1 < args.len() => {
                title = args[i + 1].clone();
                i += 2;
            }
            "--artist" if i + 1 < args.len() => {
                artist = args[i + 1].clone();
                i += 2;
            }
            "--album" if i + 1 < args.len() => {
                album = args[i + 1].clone();
                i += 2;
            }
            "--art" if i + 1 < args.len() => {
                art = args[i + 1].clone();
                i += 2;
            }
            "--action" if i + 1 < args.len() => {
                action = args[i + 1].clone();
                i += 2;
            }
            _ => {
                i += 1;
            }
        }
    }

    if spectrum_mode {
        run_spectrum_streamer();
        return;
    }

    let out = if !action.is_empty() {
        handle_action(&action, &title, &artist)
    } else {
        build_queue(&title, &artist, &album, &art)
    };
    println!("{}", out.to_json_string());
}
