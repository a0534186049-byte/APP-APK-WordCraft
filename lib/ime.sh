#!/usr/bin/env bash
# Route Android DeleteSurrounding(1, 0) at a paragraph start through WordCraft's
# ordinary Backspace command. This keeps paragraph joining consistent with desktop.

set -euo pipefail

SRC="${1:?source dir}"
APP="${2:?app}"
TITLE="${3:-WordCraft}"

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

old_legacy = """pub(super) fn delete_surrounding(app: &mut WordApp, before: usize, after: usize) {
    delete_surrounding_common(app, before, after, wordcraft_doc::ime_text::DeleteUnit::Chars);
}"""
new_legacy = """pub(super) fn delete_surrounding(app: &mut WordApp, before: usize, after: usize) {
    // Android sends one Backspace at a paragraph start as DeleteSurrounding(1, 0).
    // The paragraph mark is outside the paragraph's text range, so use the normal key command.
    if before == 1 && after == 0
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

old_modern = """pub(super) fn delete_surrounding(app: &mut WordApp, pass: &ToolPass, ctx: &egui::Context, before: usize, after: usize) {
    delete_surrounding_common(app, pass, ctx, before, after, wordcraft_doc::ime_text::DeleteUnit::Chars);
}"""
new_modern = """pub(super) fn delete_surrounding(app: &mut WordApp, pass: &ToolPass, ctx: &egui::Context, before: usize, after: usize) {
    // Android sends one Backspace at a paragraph start as DeleteSurrounding(1, 0).
    // The paragraph mark is outside the paragraph's text range, so use the normal key command.
    if before == 1 && after == 0
        && app.session.math.is_none()
        && app.session.sel.is_collapsed()
        && app.session.sel.focus.off == 0
    {
        let before_stamp = ime_stamp(app);
        if app.session.typing_open() {
            app.session.join_next_undo();
        }
        if app.run_ime("text.backspace", json!({})).is_err() {
            refuse_ime_request(app);
            return;
        }
        let after_stamp = ime_stamp(app);
        let outcome = app.session.ime_edit_outcome();
        ime_report(app, pass, ctx, before_stamp, after_stamp, outcome);
        return;
    }
    delete_surrounding_common(app, pass, ctx, before, after, wordcraft_doc::ime_text::DeleteUnit::Chars);
}"""

current = ime.read_text()
if old_modern in current:
    ime.write_text(current.replace(old_modern, new_modern, 1))
elif old_legacy in current:
    ime.write_text(current.replace(old_legacy, new_legacy, 1))
elif new_modern in current or new_legacy in current:
    pass
else:
    raise SystemExit("Unsupported delete_surrounding implementation; refusing an unsafe IME patch.")

marker = "/// The agent's rewrite belongs to the typing it corrects: one Undo takes back the typing"
test = r'''/// Android Backspace at a paragraph start must join the paragraph above.
#[test]
fn delete_surrounding_at_a_paragraph_start_joins_it_with_the_one_above() {
    let mut h = alt_frame_app();
    run(&mut h, "document.setText", json!({"text": "one\ntwo"}));
    run(&mut h, "caret.docStart", json!({}));
    for _ in 0..4 {
        run(&mut h, "caret.right", json!({}));
    }
    alt_frame(&mut h, vec![surround(1, 0)]);
    assert_eq!(body(h.state()), "onetwo");

    // At the beginning of the document there is no paragraph mark before the caret.
    run(&mut h, "caret.docStart", json!({}));
    alt_frame(&mut h, vec![surround(1, 0)]);
    assert_eq!(body(h.state()), "onetwo");
}

'''
test_source = tests.read_text()
test_name = "fn delete_surrounding_at_a_paragraph_start_joins_it_with_the_one_above()"
if test_name not in test_source:
    if test_source.count(marker) != 1:
        raise SystemExit("IME regression test insertion point is missing or ambiguous.")
    tests.write_text(test_source.replace(marker, test + marker, 1))

print("Installed Android DeleteSurrounding paragraph-start handling and regression test.")
PY

# Format WordCraft after this app-specific Rust patch so the CI preflight and build use a clean tree.
(cd "$SRC" && cargo fmt --all)
