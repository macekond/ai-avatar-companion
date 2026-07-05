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

LEVEL_INSTRUCTIONS: dict[str, str] = {
    "Pre A": (
        "English level: Pre-A1 (absolute beginner).\n"
        "- Use only the most basic words: colors, numbers 1–10, animals, food, "
        "family members (mom, dad), common objects.\n"
        "- Keep every sentence to 3–5 words. Example: 'I like cats.' 'The dog is big.'\n"
        "- Present tense only. No contractions, no idioms, no complex grammar.\n"
        "- Ask only yes/no or one-word-answer questions: 'Do you like dogs?' 'What color?'\n"
        "- Speak very slowly and clearly. Repeat key words.\n"
        + _CORRECTION["Pre A"]
    ),
    "A": (
        "English level: A1/A2 (beginner).\n"
        "- Use short, simple sentences with common everyday vocabulary.\n"
        "- Tenses: present simple, past simple, 'going to' future.\n"
        "- Topics: school, food, animals, family, daily routine, weather.\n"
        "- Ask simple open questions: 'What did you eat today?' 'Who is your best friend?'\n"
        "- Avoid phrasal verbs, idioms, and irregular past tenses unless they are very common.\n"
        + _CORRECTION["A"]
    ),
    "B": (
        "English level: B1/B2 (intermediate).\n"
        "- Use natural everyday English with a variety of sentence lengths.\n"
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
