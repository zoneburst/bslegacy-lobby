extends RefCounted
class_name BSS
##
## Central vocabulary for the rules engine.
##
## Every numeric constant here maps to a paragraph in the Battle Spirits Saga
## Comprehensive Rules v1.7.0. Section references are given in comments so that
## a rules dispute can be traced from code straight back to the rulebook.
##

# --- 2-3-2 Card types -------------------------------------------------------
enum CardType { SPIRIT, NEXUS, MAGIC }

# --- 2-4-1-1 Colours --------------------------------------------------------
# Order matters: it is the order used by the deck editor colour filter and the
# order the six reduction-symbol slots are drawn in.
#
# Named CardColor, not Color: GDScript reserves `Color` for the built-in RGBA
# type, and an enum of that name fails to parse. The same applies to any other
# member added here -- check it against the engine's global types first.
enum CardColor { RED, PURPLE, WHITE, YELLOW, GREEN, BLUE }

# --- 3-1-1 Areas ------------------------------------------------------------
enum Zone { DECK, HAND, TRASH, FIELD, RESERVE, LIFE, BURST, VOID, REMOVED }

# --- 4-4-1 Card orientation -------------------------------------------------
enum Orientation { REFRESHED, EXHAUSTED }

# --- 6-1-1 Turn steps -------------------------------------------------------
enum Step { START, CORE, DRAW, REFRESH, MAIN, ATTACK, END }

# --- 7-1 Battle sub-phases --------------------------------------------------
enum BattlePhase {
	NONE,
	ATTACK_DECLARED,      # 7-1-1
	FLASH_BEFORE_BLOCK,   # 7-1-2
	BLOCK_DECLARATION,    # 7-1-3
	FLASH_AFTER_BLOCK,    # 7-1-4
	RESOLUTION,           # 7-1-5
	BATTLE_END,           # 7-1-6
}

# --- 8-1-2 Effect categories ------------------------------------------------
enum EffectKind { ACTIVATED, CONSTANT, TRIGGERED, MAGIC }

# --- 8-1-3-1 / 8-1-6-1 Activation windows -----------------------------------
# ActivationWindow, not Window: `Window` is a native class (the OS window) and
# shadowing it is a parse error.
enum ActivationWindow { MAIN, FLASH, BOTH }

# --- 11 Keyword effects -----------------------------------------------------
enum Keyword {
	AWAKEN,     # 11-1  activated: move cores onto this spirit
	CONFRONT,   # 11-2  constant: defender must block if able
	CURSE,      # 11-3  triggered: destroy the blocker at end of battle
	IMMORTAL,   # 11-4  triggered: summon from trash
	ARMOR,      # 11-5  constant: cannot be selected by listed colours
	LUSTER,     # 11-6  triggered: return magic used this battle to hand
	BLESSED,    # 11-7  triggered: +1 life core on successful damage
	ASCEND,     # 11-8  summon cost: strip cores from a qualifying spirit
	SWIFT,      # 11-9  activated: summon during a flash window
	GALE,       # 11-10 triggered: blocker exhausts N of their spirits
	CRUSH,      # 11-11 triggered: mill level + modifier
	RAID,       # 11-12 triggered: exhaust a nexus to refresh the attacker
	AT_FIELD,   # 11-13 constant: destruction immunity while a soul core is on it
	ASTRAL,     # 11-14 constant: only blockable by spirits with Astral
	CHAIN,      # 11-15 conditional continuation of another effect
	AGILE,      # 11-16 triggered from hand: swap a cheaper spirit out after battle
	FEAST,      # 11-17 Supsprite token escalation
	LINK,       # 11-18 triggered: lend BP and symbols to an attacker
	BLOODCURSE, # (0.14.0, Set 1) when destroyed by the opponent: pay a life and a core to stay
	INHERIT,    # (0.19.1) 継召: EX symbols on cards in your trash may pay reduction; those cards leave the game
}

const KEYWORD_NAMES := {
	Keyword.AWAKEN: "Awaken", Keyword.CONFRONT: "Confront", Keyword.CURSE: "Curse",
	Keyword.IMMORTAL: "Immortal", Keyword.ARMOR: "Armor", Keyword.LUSTER: "Luster",
	Keyword.BLESSED: "Blessed", Keyword.ASCEND: "Ascend", Keyword.SWIFT: "Swift",
	Keyword.GALE: "Gale", Keyword.CRUSH: "Crush", Keyword.RAID: "Raid",
	Keyword.AT_FIELD: "A.T. Field", Keyword.ASTRAL: "Astral", Keyword.CHAIN: "Chain",
	Keyword.AGILE: "Agile", Keyword.FEAST: "Feast", Keyword.LINK: "Link",
	Keyword.INHERIT: "Inherit",
	Keyword.BLOODCURSE: "Bloodcurse",
}

const COLOR_NAMES := ["red", "purple", "white", "yellow", "green", "blue"]
const CARD_TYPE_NAMES := ["spirit", "nexus", "magic"]

# --- 5-1-1-1 / 5-2 Setup constants -----------------------------------------
const DECK_MIN := 50
const DECK_MAX := 60
const MAX_COPIES := 4            # 5-1-1-1 four or fewer copies per card name
const STARTING_LIFE := 5         # 5-2-3
const STARTING_RESERVE := 3      # 5-2-4 (plus one soul core)
const OPENING_HAND := 4          # 5-2-5
const NO_MULLIGAN_BONUS := 1     # 5-2-7 players who keep draw one extra
const MAX_BURST_SET_PER_TURN := 1  # 6-6-1-2-2

# --- Player action verbs sent over the wire --------------------------------
class Action:
	const SUMMON := "summon"
	const PLACE := "place"
	const USE_MAGIC := "use_magic"
	const SET_BURST := "set_burst"
	const MOVE_CORE := "move_core"
	const ACTIVATE := "activate"
	const END_MAIN := "end_main"
	const DECLARE_ATTACK := "declare_attack"
	const DECLARE_BLOCK := "declare_block"
	const DECLINE_BLOCK := "decline_block"
	const FLASH_PASS := "flash_pass"
	const END_ATTACK := "end_attack"
	const RESOLVE_CHOICE := "resolve_choice"
	const ACTIVATE_BURST := "activate_burst"
	const DECLINE_BURST := "decline_burst"
	const CONCEDE := "concede"
	const MULLIGAN := "mulligan"
	const KEEP_HAND := "keep_hand"
	const CHOOSE_ORDER := "choose_order"   # 0.20.0: the coin-toss winner goes first ("first": true) or second


static func color_from_string(s: String) -> int:
	var idx := COLOR_NAMES.find(s.to_lower())
	return idx if idx >= 0 else -1


static func card_type_from_string(s: String) -> int:
	var idx := CARD_TYPE_NAMES.find(s.to_lower())
	return idx if idx >= 0 else -1


static func keyword_from_string(s: String) -> int:
	var norm := s.to_lower().replace(".", "").replace(" ", "")
	for k in KEYWORD_NAMES:
		if KEYWORD_NAMES[k].to_lower().replace(".", "").replace(" ", "") == norm:
			return k
	return -1
