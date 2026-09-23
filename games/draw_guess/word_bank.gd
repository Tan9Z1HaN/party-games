class_name WordBank
extends RefCounted

## 词库。局域网版没有远端下发，词库随版本内置。
##
## CSV 列：id,word,difficulty,category,synonyms,disabled
## - difficulty：1 简单 / 2 中等 / 3 困难
## - synonyms：多个同义词用 `|` 分隔（CSV 的逗号是列分隔符，不能借用）
## - disabled：留空即启用，方便临时下线某个词而不删行
##
## 词条统一用字典表示：
##   { id:int, word:String, difficulty:int, category:String,
##     synonyms:PackedStringArray, disabled:bool }

## 注意扩展名是 .txt 而不是 .csv。
## Godot 会把 *.csv 当成翻译表自动导入，生成一堆 .translation 文件；
## 更麻烦的是**被导入的源文件不会被打进导出包**，
## 于是编辑器里跑得好好的，导出后 FileAccess 打不开词库。
## 换成 Godot 没有导入器的扩展名，文件才会原样进包。
const DEFAULT_PATH := "res://data/words/words.txt"

## 难度系数，直接参与计分
const DIFFICULTY_MULTIPLIER := {1: 0.8, 2: 1.0, 3: 1.3}

const DIFFICULTY_NAMES := {1: "简单", 2: "中等", 3: "困难"}

var _entries: Array = []
var _by_difficulty := {}


static func load_default() -> WordBank:
	return load_from(DEFAULT_PATH)


static func load_from(path: String) -> WordBank:
	var bank := WordBank.new()
	bank._load(path)
	return bank


func _load(path: String) -> void:
	_entries.clear()
	_by_difficulty.clear()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("词库打不开：%s" % path)
		return

	var header := file.get_csv_line()
	if header.is_empty():
		push_error("词库没有表头：%s" % path)
		return

	# 有些编辑器写出的 UTF-8 CSV 带 BOM，会把第一个列名变成 "\ufeffid"
	var first := header[0].strip_edges()
	if first.begins_with("\ufeff"):
		first = first.substr(1)
	var columns := {"id": 0, "word": 1, "difficulty": 2, "category": 3, "synonyms": 4, "disabled": 5}
	for i in header.size():
		var name := header[i].strip_edges()
		if name.begins_with("\ufeff"):
			name = name.substr(1)
		if name in columns:
			columns[name] = i

	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() < 3:
			continue
		var word := _cell(row, columns["word"]).strip_edges()
		if word.is_empty():
			continue

		var entry := {
			"id": _cell(row, columns["id"]).strip_edges().to_int(),
			"word": word,
			"difficulty": clampi(_cell(row, columns["difficulty"]).strip_edges().to_int(), 1, 3),
			"category": _cell(row, columns["category"]).strip_edges(),
			"synonyms": _split_synonyms(_cell(row, columns["synonyms"])),
			"disabled": _cell(row, columns["disabled"]).strip_edges() == "1",
		}
		_entries.append(entry)
		var d: int = entry["difficulty"]
		if not _by_difficulty.has(d):
			_by_difficulty[d] = []
		_by_difficulty[d].append(_entries.size() - 1)

	file.close()


func _cell(row: PackedStringArray, index: int) -> String:
	if index < 0 or index >= row.size():
		return ""
	return row[index]


func _split_synonyms(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in text.split("|", false):
		var s := part.strip_edges()
		if not s.is_empty():
			out.append(s)
	return out


## 抽 count 道题。优先从指定难度取；该难度不够时用其它难度补齐。
## exclude 里的词会被跳过，用来避免同一局重复出题。
func pick(difficulty: int, count: int, exclude: PackedStringArray = PackedStringArray()) -> Array:
	var picked := _pick_from(difficulty, count, exclude)
	if picked.size() < count:
		var already := PackedStringArray()
		for e in picked:
			already.append(e["word"])
		already.append_array(exclude)
		picked.append_array(_pick_from(0, count - picked.size(), already))
	return picked


func _pick_from(difficulty: int, count: int, exclude: PackedStringArray) -> Array:
	var pool: Array = []
	for entry in _entries:
		if entry["disabled"]:
			continue
		if difficulty > 0 and entry["difficulty"] != difficulty:
			continue
		if exclude.has(entry["word"]):
			continue
		pool.append(entry)
	pool.shuffle()
	return pool.slice(0, mini(count, pool.size()))


func count_of(difficulty: int) -> int:
	if difficulty <= 0:
		return _entries.size()
	return _by_difficulty.get(difficulty, []).size()


func find_by_word(word: String) -> Dictionary:
	for entry in _entries:
		if entry["word"] == word:
			return entry
	return {}


func all_words() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in _entries:
		out.append(entry["word"])
	return out


func total() -> int:
	return _entries.size()


## 判定猜测是否正确。会做规范化并检查同义词表。
func matches(entry: Dictionary, guess: String) -> bool:
	var g := normalize(guess)
	if g.is_empty():
		return false
	if g == normalize(entry["word"]):
		return true
	for syn in entry["synonyms"]:
		if g == normalize(syn):
			return true
	return false


## 猜测是否"接近答案"，用于给出"接近了"的提示。
func is_close(entry: Dictionary, guess: String, threshold: int = 1) -> bool:
	var g := normalize(guess)
	var target := normalize(entry["word"])
	if g.is_empty() or target.is_empty():
		return false
	if absi(g.length() - target.length()) > threshold:
		return false
	return levenshtein(g, target) <= threshold


## 文本规范化：全角转半角、去空格与标点、统一小写。
## 中文没有大小写问题，但玩家可能用英文或夹杂标点。
static func normalize(text: String) -> String:
	var lowered := text.strip_edges().to_lower()
	var out := ""
	for i in lowered.length():
		var code := lowered.unicode_at(i)
		if code >= 0xFF01 and code <= 0xFF5E:
			code -= 0xFEE0        # 全角 ASCII -> 半角
		elif code == 0x3000:
			code = 0x20           # 全角空格
		var ch := String.chr(code)
		if _is_ignorable(ch):
			continue
		out += ch
	return out


static func _is_ignorable(ch: String) -> bool:
	if ch == " " or ch == "\t" or ch == "\n" or ch == "\r":
		return true
	return ch in "-_/\\.,!?;:'\"()[]{}<>~`@#$%^&*+=|、。，！？；：（）【】《》〈〉「」『』·…—"


## 编辑距离。用滚动数组，O(min(m,n)) 空间。
static func levenshtein(a: String, b: String) -> int:
	if a == b:
		return 0
	if a.is_empty():
		return b.length()
	if b.is_empty():
		return a.length()

	# 让 b 是较短的那个，节省内存
	if a.length() < b.length():
		var tmp := a
		a = b
		b = tmp

	var prev := []
	var curr := []
	for j in range(b.length() + 1):
		prev.append(j)

	for i in range(1, a.length() + 1):
		curr = [i]
		for j in range(1, b.length() + 1):
			var cost := 0 if a.unicode_at(i - 1) == b.unicode_at(j - 1) else 1
			curr.append(mini(mini(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost))
		prev = curr

	return prev[b.length()]
