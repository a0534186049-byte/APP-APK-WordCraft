#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare the upstream WordCraft checkout for a Hebrew Android edition.
# Only this temporary checkout is patched; the official source repository is never changed.
prepare_wordcraft_hebrew() {
    local src="$1"
    local root="$2"
    local i18n_dir="$root/source/craft-i18n"
    local pin current_origin

    [[ -f "$src/craft-i18n.rev" ]] || {
        echo "ERROR: WordCraft's pinned craft-i18n.rev is missing in $src" >&2
        return 1
    }
    pin="$(tr -d '[:space:]' < "$src/craft-i18n.rev")"
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || {
        echo "ERROR: Invalid craft-i18n revision: $pin" >&2
        return 1
    }

    mkdir -p "$root/source"
    if [[ -e "$i18n_dir" ]]; then
        [[ -d "$i18n_dir/.git" ]] || {
            echo "ERROR: $i18n_dir exists but is not a Git checkout; refusing to overwrite it." >&2
            return 1
        }
        current_origin="$(git -C "$i18n_dir" remote get-url origin 2>/dev/null || true)"
        [[ "${current_origin%.git}" == "https://github.com/storytold/craft-i18n" ]] || {
            echo "ERROR: Unexpected craft-i18n origin '$current_origin'; refusing to reuse it." >&2
            return 1
        }
        git -C "$i18n_dir" fetch --depth 1 origin "$pin"
        git -C "$i18n_dir" checkout --detach "$pin"
    else
        git clone --filter=blob:none --no-checkout https://github.com/storytold/craft-i18n.git "$i18n_dir"
        git -C "$i18n_dir" fetch --depth 1 origin "$pin"
        git -C "$i18n_dir" checkout --detach "$pin"
    fi

    [[ "$(git -C "$i18n_dir" rev-parse HEAD)" == "$pin" ]] || {
        echo "ERROR: craft-i18n checkout does not match WordCraft's pin $pin" >&2
        return 1
    }
    [[ -s "$i18n_dir/locales/he/wordcraft.tsv" && -s "$i18n_dir/locales/he/common.tsv" ]] || {
        echo "ERROR: The pinned craft-i18n revision does not contain both Hebrew catalogs." >&2
        return 1
    }

    # WordCraft's build.rs embeds every available locale from this directory. In release builds,
    # REQUIRED makes a missing catalog a hard build error instead of silently shipping English.
    export CRAFT_I18N_DIR="$i18n_dir"
    export CRAFT_I18N_REQUIRED=1

    python3 - "$src" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
i18n = src / "crates/ui-egui/src/i18n.rs"
tests = src / "crates/ui-egui/src/i18n/tests.rs"
engine_tests = src / "crates/engine/src/tests/typing.rs"
rtl = src / "crates/ui-egui/src/rtl.rs"

for path in (i18n, tests, engine_tests, rtl):
    if not path.is_file():
        raise SystemExit(f"Required WordCraft source file is missing: {path}")

text = i18n.read_text()
if 'pub static LANGUAGES: [LangInfo; 28] = [' in text:
    text = text.replace(
        'pub static LANGUAGES: [LangInfo; 28] = [',
        'pub static LANGUAGES: [LangInfo; 29] = [',
        1,
    )
elif 'pub static LANGUAGES: [LangInfo; 29] = [' not in text:
    raise SystemExit("Unexpected LANGUAGES array; refusing an unsafe source patch.")

he_entry = '    LangInfo { code: "he", prefer_hans: false, editing_lang: Some("he-IL") },'
ar_entry = '    LangInfo { code: "ar", prefer_hans: false, editing_lang: None },'
if he_entry not in text:
    if text.count(ar_entry) != 1:
        raise SystemExit("Could not find exactly one Arabic language entry to extend.")
    text = text.replace(ar_entry, ar_entry + "\n" + he_entry, 1)

if 'const RTL_LANGUAGES: [&str; 1] = ["ar"];' in text:
    text = text.replace(
        'const RTL_LANGUAGES: [&str; 1] = ["ar"];',
        'const RTL_LANGUAGES: [&str; 2] = ["ar", "he"];',
        1,
    )
elif 'const RTL_LANGUAGES: [&str; 2] = ["ar", "he"];' not in text:
    raise SystemExit("Unexpected RTL_LANGUAGES declaration; refusing an unsafe source patch.")

system_locale = '''    let tags: Vec<String> = sys_locale::get_locales().take(16).collect();
    first_supported(tags.iter().map(String::as_str)).unwrap_or(Lang::EN)'''
android_system_locale = '''    // The Android package is the Hebrew edition: fresh installs use Hebrew even when the
    // device's system language is English. The user can still choose English in WordCraft.
    #[cfg(target_os = "android")]
    {
        return Lang::from_code("he").unwrap_or(Lang::EN);
    }
    #[cfg(not(target_os = "android"))]
    {
        let tags: Vec<String> = sys_locale::get_locales().take(16).collect();
        first_supported(tags.iter().map(String::as_str)).unwrap_or(Lang::EN)
    }'''
if system_locale in text:
    text = text.replace(system_locale, android_system_locale, 1)
elif android_system_locale not in text:
    raise SystemExit("Could not find system-language detection code to set the Android default.")

i18n.write_text(text)

test_text = tests.read_text()
locale_cases = '''        ("fr-FR", Some(lang("fr"))),'''
hebrew_cases = '''        ("he", Some(lang("he"))),
        ("he-IL", Some(lang("he"))),
        ("he_IL.UTF-8", Some(lang("he"))),
        ("HE-il", Some(lang("he"))),
        ("fr-FR", Some(lang("fr"))),'''
if locale_cases in test_text:
    test_text = test_text.replace(locale_cases, hebrew_cases, 1)
elif hebrew_cases not in test_text:
    raise SystemExit("Could not extend system-locale tests with Hebrew.")

rtl_assert = '    assert!(Lang::all().filter(|l| l.rtl()).eq([ar]), "Arabic is the only right-to-left language");'
rtl_assert_new = '''    let he = lang("he");
    assert!(he.rtl());
    assert!(
        Lang::all().filter(|l| l.rtl()).map(Lang::code).eq(["ar", "he"]),
        "Arabic and Hebrew are the right-to-left interface languages"
    );'''
if rtl_assert in test_text:
    test_text = test_text.replace(rtl_assert, rtl_assert_new, 1)
elif not (
    'let he = lang("he");' in test_text
    and "assert!(he.rtl());" in test_text
    and '.eq(["ar", "he"])' in test_text
    and "Arabic and Hebrew are the right-to-left interface languages" in test_text
):
    # rustfmt runs at the end of this helper, so a second invocation sees the same
    # assertion in formatted layout rather than the exact pre-format replacement text.
    raise SystemExit("Could not confirm the existing Hebrew RTL language-list assertion.")

new_hebrew_test = r'''
/// The embedded Hebrew catalog is selectable, translated and mirrored; its saved preference
/// survives a restart without changing the document being edited.
#[test]
fn hebrew_locales_and_saved_preference_work_without_changing_the_document() {
    needs_catalogs!();
    let he = lang("he");
    for tag in ["he", "he-IL", "he_IL.UTF-8", "HE-il"] {
        assert_eq!(lang_from_tag(tag), Some(he), "{tag}");
    }
    assert_eq!(he.name(), "עברית");
    assert!(he.rtl());
    assert_eq!(tr(he, "Blank document"), "מסמך ריק");
    assert_eq!(tr(he, "Word Count"), "ספירת מילים");
    assert_eq!(tr(he, "Font…"), "גופן…");
    assert_eq!(tr(he, "About"), "אודות");
    set_current(he);
    assert!(crate::rtl::on());
    assert_eq!(location("Blank document › Word Count"), "מסמך ריק ‹ ספירת מילים");
    assert_eq!(isolate("מסמך.docx"), "\u{2068}מסמך\u{200E}.docx\u{2069}");
    set_current(Lang::EN);

    let mut app = crate::WordApp::new(
        wordcraft_engine::Session::new(wordcraft_engine::sample::sample_document()),
        Default::default(),
    );
    let before = serde_json::to_value(&app.session.doc).unwrap();
    let result = app.run("ui.language", serde_json::json!({"value": "he"})).unwrap();
    assert_eq!(result["effective"], "he");
    assert_eq!(app.ui.language, "he");
    assert_eq!(serde_json::to_value(&app.session.doc).unwrap(), before);
    let saved = serde_json::to_string(&app.ui).unwrap();
    let restored: crate::UiState = serde_json::from_str(&saved).unwrap();
    assert_eq!(Lang::from_pref(&restored.language), he);
}
'''
if "fn hebrew_locales_and_saved_preference_work_without_changing_the_document()" not in test_text:
    test_text = test_text.rstrip() + "\n\n" + new_hebrew_test.lstrip()
tests.write_text(test_text)

engine = engine_tests.read_text()
test_anchor = '''    let s = typed("سلام");
    assert_eq!(bidi(&s, 0), Some(true));'''
hebrew_engine = '''    let s = typed("سلام");
    assert_eq!(bidi(&s, 0), Some(true));
    let s = typed("שלום");
    assert_eq!(bidi(&s, 0), Some(true), "Hebrew typed first makes the paragraph RTL");'''
if test_anchor in engine:
    engine = engine.replace(test_anchor, hebrew_engine, 1)
elif hebrew_engine not in engine:
    raise SystemExit("Could not add the Hebrew first-character RTL regression test.")
engine_tests.write_text(engine)

rtl_text = rtl.read_text()
rtl_text = rtl_text.replace(
    "//! Mirrored window layout for a right-to-left interface language (Arabic).",
    "//! Mirrored window layout for right-to-left interface languages (Arabic and Hebrew).",
    1,
)
rtl.write_text(rtl_text)

# WordCraft's desktop status row has a full zoom slider and optional indicators.
# On narrow portrait screens, keep the primary controls visible and move the rest to a menu.
chrome = src / "crates/ui-egui/src/chrome.rs"
chrome_text = chrome.read_text()
compact_marker = "// WordCraft mobile status row: fit the page/count/zoom essentials on portrait screens."
compact_guard = """            if not app.has_document() {
                return;
            }
            let rtl = crate::rtl::on();"""
compact_replacement = """            if not app.has_document() {
                return;
            }
""" + r'''            // WordCraft mobile status row: fit the page/count/zoom essentials on portrait screens.
            if ui.available_width() < 560.0 {
                let l = app.session.layout();
                let page = if let Some(p) = app.canvas.viewed_page {
                    p.min(l.pages.len().saturating_sub(1)) + 1
                } else if app.session.selects_whole_story() {
                    app.session.page_hint.min(l.pages.len().saturating_sub(1)) + 1
                } else {
                    l.caret_on(&app.session.sel.focus, app.session.page_hint)
                        .map(|c| c.page + 1)
                        .unwrap_or(1)
                };
                let unit = app.ui.status_count;
                let counts = app.cached_status_counts();
                let wtxt = if app.session.sel.is_collapsed() || crate::objects::selected(app).is_some() {
                    status_count_text(unit, counts.in_unit(unit), None)
                } else {
                    let selected = crate::count_in_unit(&app.session.selected_text(), unit);
                    status_count_text(unit, counts.in_unit(unit), Some(selected))
                };
                let reading = app.session.view.read_mode;
                let zoom = (if reading {
                    app.session.view.read_zoom
                } else {
                    app.canvas.scale / crate::canvas::PX_PER_PT
                } * 100.0)
                    .round();
                crate::rtl::root(ui, |ui| {
                    ui.horizontal_centered(|ui| {
                        ui.spacing_mut().item_spacing = vec2(5.0, 0.0);
                        if ui.small_button(format!("{page}/{}", l.pages.len())).clicked() {
                            let _ = app.run("ui.dialog", json!({"name": "goto"}));
                        }
                        if ui.small_button(wtxt.as_str()).clicked() {
                            let _ = app.run("ui.dialog", json!({"name": "wordCount"}));
                        }
                        if ui.small_button(format!("{zoom:.0}%")).clicked() && !reading {
                            let _ = app.run("ui.dialog", json!({"name": "zoom"}));
                        }
                        ui.menu_button("⋯", |ui| {
                            ui.set_min_width(210.0);
                            if reading {
                                if ui.button(tl!("Zoom In")).clicked() {
                                    let _ = app.run(
                                        "view.readTextSize",
                                        json!({"value": (zoom + 10.0).min(150.0)}),
                                    );
                                    ui.close();
                                }
                                if ui.button(tl!("Zoom Out")).clicked() {
                                    let _ = app.run(
                                        "view.readTextSize",
                                        json!({"value": (zoom - 10.0).max(75.0)}),
                                    );
                                    ui.close();
                                }
                            } else {
                                if ui.button(tl!("Zoom In")).clicked() {
                                    let _ = app.run("view.zoomIn", json!({}));
                                    ui.close();
                                }
                                if ui.button(tl!("Zoom Out")).clicked() {
                                    let _ = app.run("view.zoomOut", json!({}));
                                    ui.close();
                                }
                            }
                            if ui.button(tl!("Word Count")).clicked() {
                                let _ = app.run("ui.dialog", json!({"name": "wordCount"}));
                                ui.close();
                            }
                            ui.separator();
                            for c in crate::StatusCount::ALL {
                                if ui
                                    .selectable_label(app.ui.status_count == c, tl!(c.label()))
                                    .clicked()
                                {
                                    let _ = app.run("ui.statusCount", json!({"value": c.code()}));
                                    ui.close();
                                }
                            }
                            ui.separator();
                            ui.menu_button(tl!("Language"), |ui| {
                                ui.set_min_width(220.0);
                                crate::rtl::root(ui, |ui| crate::ribbon::language_menu(ui, app));
                            });
                            if ui.button(tl!("Web Layout")).clicked() {
                                let _ = app.run("view.webLayout", json!({}));
                                ui.close();
                            }
                            if ui.button(tl!("Print Layout")).clicked() {
                                let _ = app.run("view.printLayout", json!({}));
                                ui.close();
                            }
                            if ui.button(tl!("Read Mode")).clicked() {
                                let _ = app.run("view.readMode", json!({}));
                                ui.close();
                            }
                            if ui.button(tl!("Focus")).clicked() {
                                let _ = app.run("view.focus", json!({}));
                                ui.close();
                            }
                        });
                    });
                });
                return;
            }
''' + """            let rtl = crate::rtl::on();"""
if compact_marker not in chrome_text:
    if chrome_text.count(compact_guard) != 1:
        raise SystemExit("Could not find the unique WordCraft status bar insertion point.")
    chrome_text = chrome_text.replace(compact_guard, compact_replacement, 1)
    chrome.write_text(chrome_text)
elif chrome_text.count(compact_marker) != 1:
    raise SystemExit("WordCraft compact status row marker is ambiguous.")
PY

    # Ensure both the official Hebrew catalog and the Android-specific RTL switches are present.
    python3 - "$i18n_dir" "$src" <<'PY'
from pathlib import Path
import sys

catalog = Path(sys.argv[1])
src = Path(sys.argv[2])
rows = {}
for name in ("common.tsv", "wordcraft.tsv"):
    lines = (catalog / "locales/he" / name).read_text(encoding="utf-8").splitlines()
    rows[name] = sum(1 for line in lines if line and not line.startswith("#") and line.count("\t") >= 2)
    if rows[name] == 0:
        raise SystemExit(f"Hebrew catalog {name} has no entries")
i18n = (src / "crates/ui-egui/src/i18n.rs").read_text()
tests = (src / "crates/ui-egui/src/i18n/tests.rs").read_text()
engine = (src / "crates/engine/src/tests/typing.rs").read_text()
chrome = (src / "crates/ui-egui/src/chrome.rs").read_text()
assert 'const RTL_LANGUAGES: [&str; 2] = ["ar", "he"];' in i18n
assert "// WordCraft mobile status row: fit the page/count/zoom essentials on portrait screens." in chrome
assert 'code: "he", prefer_hans: false, editing_lang: Some("he-IL")' in i18n
assert "hebrew_locales_and_saved_preference_work_without_changing_the_document" in tests
assert 'let s = typed("שלום");' in engine
print(f"Hebrew catalogs verified: {rows['common.tsv']} shared rows, {rows['wordcraft.tsv']} WordCraft rows.")
print("Hebrew UI language, Android RTL default and Hebrew typing regression checks are installed.")
PY

    # Keep the temporary Android source checkout rustfmt-clean. The helper edits only this
    # disposable checkout; the upstream repository is not modified.
    (cd "$src" && cargo fmt --all)

    echo "  -> embedded the official pinned Hebrew interface catalogs"
    echo "  -> Android WordCraft defaults to Hebrew UI and right-to-left layout"
}
