#!/usr/bin/env bash
# Android IMEs can send DeleteSurrounding(1, 0) for Backspace at a paragraph start.
# Route that exact case through WordCraft's ordinary Backspace command, which joins paragraphs.
set -euo pipefail

SRC="$1"
APP="$2"
TITLE="$3"
if [[ -z "$SRC" || -z "$APP" ]]; then
    echo "Usage: ime.sh <source-dir> <app> <title>" >&2
    exit 2
fi

if [[ "$APP" != "wordcraft" ]]; then
    exit 0
fi

python3 - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
ime = src / "crates/ui-egui/src/keys/ime.rs"
tests = src / "crates/ui-egui/src/keys/tests.rs"
for path in (ime, tests):
    if not path.is_file():
        raise SystemExit(f"Required WordCraft IME source is missing: {path}")

old = """pub(super) fn delete_surrounding(app: &mut WordApp, before: usize, after: usize) {
    delete_surrounding_common(app, before, after, wordcraft_doc::ime_text::DeleteUnit::Chars);
}"""
new = """pub(super) fn delete_surrounding(app: &mut WordApp, before: usize, after: usize) {
    // Android IMEs commonly express one Backspace at the beginning of a paragraph as
    // DeleteSurrounding(1, 0). The paragraph mark is not part of the paragraph text, so the
    // ordinary surrounding-text range is empty. Use WordCraft's Backspace command here.
    if before == 1
        && after == 0
        && app.session.math.is_none()
        && app.session.sel.is_collapsed()
        && app.session.sel.focus.off == 0
    {
        if app.session.typing_open() {
            app.session.join_next_undo();
        }
        let _ = app.run("text.backspace", json!({}));
        return;
    }
    delete_surrounding_common(app, before, after, wordcraft_doc::ime_text::DeleteUnit::Chars);
}"""
current = ime.read_text()
if old in current:
    ime.write_text(current.replace(old, new, 1))
elif new not in current:
    raise SystemExit("Unexpected delete_surrounding implementation; refusing an unsafe IME patch.")

marker = "/// The agent's rewrite belongs to the typing it corrects: one Undo takes back the typing"
test = r'''/// Android Backspace at a paragraph start must join the paragraph above.
#[test]
fn delete_surrounding_at_a_paragraph_start_joins_it_with_the_one_above() {
    let (ctx, mut a) = alt_frame_app();
    a.run("document.setText", json!({"text": "one\ntwo"})).unwrap();
    a.run("caret.docStart", json!({})).unwrap();
    for _ in 0..4 {
        a.run("caret.right", json!({})).unwrap();
    }
    alt_frame(&ctx, &mut a, vec![surround(1, 0)]);
    assert_eq!(body(&a), "onetwo");

    // At the beginning of the document there is no paragraph to join.
    a.run("caret.docStart", json!({})).unwrap();
    alt_frame(&ctx, &mut a, vec![surround(1, 0)]);
    assert_eq!(body(&a), "onetwo");

    // A multi-character correction at the paragraph start must not join paragraphs.
    a.run("document.setText", json!({"text": "one\ntwo"})).unwrap();
    a.run("caret.docStart", json!({})).unwrap();
    for _ in 0..4 {
        a.run("caret.right", json!({})).unwrap();
    }
    alt_frame(&ctx, &mut a, vec![surround(2, 0), egui::Event::Text("X".into())]);
    assert_eq!(body(&a), "one\nXtwo");
}

'''
test_source = tests.read_text()
if "fn delete_surrounding_at_a_paragraph_start_joins_it_with_the_one_above()" not in test_source:
    if test_source.count(marker) != 1:
        raise SystemExit("IME regression test insertion point is missing or ambiguous.")
    tests.write_text(test_source.replace(marker, test + marker, 1))
print("Installed the Android paragraph-start Backspace patch and regression test.")
PY

# Format WordCraft after this app-specific Rust patch so the CI preflight and build use
# a clean tree. The Hebrew preparation step has already formatted its own changes.
(cd "$SRC" && cargo fmt --all)
