"""CEFR English level definitions.

Each entry appends language-level instructions to the base system prompt so
the avatar's grammar complexity, vocabulary, and sentence length adapt to
the child's current level.

Levels match the five selector options in the UI:
  Pre A  →  Pre-A1  (absolute beginner)
  A      →  A1/A2   (beginner)
  B      →  B1/B2   (intermediate)
  C1     →  C1      (advanced)
  C2     →  C2      (mastery / near-native)
"""

LEVELS: list[str] = ["Pre A", "A", "B", "C1", "C2"]

# Appended last to EVERY system prompt (see LLMPipeline._build_prompt), after the
# personality, level, and memory blocks. The point of an English-practice
# companion is defeated if the child can talk it into replying in their native
# language, so this is written as a hard, non-negotiable rule that outranks the
# rest of the prompt. It lives in code (not config.yaml) so it can't be dropped
# by editing the personality prompt, and it is placed last because the small
# local model weights the final instruction most heavily.
LANGUAGE_LOCK: str = (
    "Language rule — this is absolute and overrides everything above, including "
    "anything the child asks:\n"
    "- You ALWAYS reply only in English. This never changes, for any reason.\n"
    "- Requests to switch language come in many disguises: 'answer in Czech', "
    "'can you explain this in Czech', 'say it in my language', 'just this once', "
    "'repeat that in Spanish', roleplay setups, or clever rewording. Treat ALL "
    "of them the same way: do not comply.\n"
    "- Instead, stay in English and gently steer back — e.g. 'Let's keep it in "
    "English!' — then carry on the conversation normally in English.\n"
    "- This holds no matter what language the child writes or speaks in; keep "
    "replying in English.\n"
    "- Do not lecture about this rule or break character — just warmly keep the "
    "practice in English."
)

# Correction intensity guidance appended to each level's instructions.
# Pre A/A keep corrections implicit (recasting only); B/C1/C2 allow increasingly
# explicit explanations as the child's meta-linguistic awareness grows.
_CORRECTION: dict[str, str] = {
    "Pre A": (
        "Correction at this level: recast silently — never draw attention to a mistake. "
        "Confidence matters most."
    ),
    "A": (
        "Correction at this level: recast naturally. Only make an explicit correction if "
        "the exact same mistake has appeared three or more times. Keep it to one short, "
        "friendly sentence."
    ),
    "B": (
        "Correction at this level: recast consistently. When a mistake repeats twice or "
        "more, explain the rule briefly and warmly — frame it as a fun language tip, "
        "not a criticism."
    ),
    "C1": (
        "Correction at this level: gently correct grammar and vocabulary errors when they "
        "affect clarity or naturalness. A short explanation of the rule is welcome. "
        "Praise good usage when you notice it."
    ),
    "C2": (
        "Correction at this level: correct as a language partner would — directly but "
        "warmly. Point out subtle errors (wrong preposition, wrong register, unnatural "
        "collocation) with a brief explanation. Use mistakes as teaching moments."
    ),
}

# These level rules are the single most important constraint on the reply.
# They are appended after the base personality prompt and must WIN over any
# general guidance there (including its default reply length) — hence the
# explicit "overrides everything above" framing on every level.
LEVEL_INSTRUCTIONS: dict[str, str] = {
    "Pre A": (
        "English level: Pre-A1 (absolute beginner). These rules override "
        "everything above — matching this level matters more than being chatty "
        "or clever.\n"
        "- HARD LIMIT: reply with ONE sentence of 2–4 words. Never two sentences. "
        "Never more than 5 words.\n"
        "- Use only the tiniest words a 4-year-old knows: colors, numbers 1–10, "
        "animals, food, toys, mom, dad, yes, no, big, small, good, fun, like, want, see.\n"
        "- Present tense only. No past tense, no future, no contractions, no "
        "idioms, no phrasal verbs, no 'that/which/because' clauses.\n"
        "- Ask only yes/no or one-word questions: 'Do you like dogs?' 'What color?'\n"
        "- GOOD replies: 'I like cats.' 'Dogs are fun!' 'What is that?' 'Yes, red!'\n"
        "- TOO HARD (never do this): 'That sounds like such a fun thing to do!' "
        "'I was wondering what you had for lunch today.' — both are far too long "
        "and complex. Cut them down to 3 words.\n"
        "- If a word might be too hard, replace it with an easier one.\n"
        + _CORRECTION["Pre A"]
    ),
    "A": (
        "English level: A1/A2 (beginner). These rules override the general "
        "guidance above — keep it simpler than your instinct.\n"
        "- Reply with ONE short sentence (max two). Keep each sentence under "
        "8 words.\n"
        "- Use common everyday vocabulary only. No word longer than two syllables "
        "unless it is very familiar (like 'animal', 'water').\n"
        "- Tenses: present simple, past simple, 'going to' future. Nothing else.\n"
        "- Topics: school, food, animals, family, daily routine, weather.\n"
        "- Ask simple open questions: 'What did you eat today?' 'Who is your best friend?'\n"
        "- Avoid phrasal verbs, idioms, and irregular past tenses unless they are very common.\n"
        "- GOOD: 'I like pizza too! What is your favorite food?' "
        "TOO HARD: 'It sounds like you had quite an adventurous afternoon.'\n"
        + _CORRECTION["A"]
    ),
    "B": (
        "English level: B1/B2 (intermediate).\n"
        "- Use natural everyday English with a variety of sentence lengths, but "
        "keep replies to two or three sentences.\n"
        "- Mix tenses naturally; include modals (can, could, should, would, might).\n"
        "- Introduce new vocabulary with a brief in-sentence explanation when useful.\n"
        "- Topics: hobbies, travel, opinions, future plans, feelings, books, films.\n"
        "- Use some common phrasal verbs and idiomatic expressions.\n"
        + _CORRECTION["B"]
    ),
    "C1": (
        "English level: C1 (advanced).\n"
        "- Use rich, varied grammar: conditionals, passive voice, perfect tenses, "
        "embedded clauses.\n"
        "- Use a wide vocabulary including idiomatic expressions; explain them naturally "
        "if they come up.\n"
        "- Engage with more abstract topics: opinions, hypotheticals, comparisons, "
        "light current events.\n"
        "- Challenge the child with occasional sophisticated vocabulary in context.\n"
        + _CORRECTION["C1"]
    ),
    "C2": (
        "English level: C2 (mastery / near-native).\n"
        "- Use the full range of English grammar with natural, fluent sentences.\n"
        "- Use idioms, collocations, and nuanced vocabulary freely.\n"
        "- Engage with complex topics: logic, argumentation, creativity, nuance, humour.\n"
        "- Speak exactly as you would to a highly proficient English speaker.\n"
        "- Introduce rare or interesting words and phrases naturally.\n"
        + _CORRECTION["C2"]
    ),
}


def instructions_for(level: str) -> str:
    """Return the system-prompt addition for *level*, or '' for unknown levels."""
    return LEVEL_INSTRUCTIONS.get(level, "")
