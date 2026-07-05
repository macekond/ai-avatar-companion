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

LEVEL_INSTRUCTIONS: dict[str, str] = {
    "Pre A": (
        "English level: Pre-A1 (absolute beginner).\n"
        "- Use only the most basic words: colors, numbers 1–10, animals, food, "
        "family members (mom, dad), common objects.\n"
        "- Keep every sentence to 3–5 words. Example: 'I like cats.' 'The dog is big.'\n"
        "- Present tense only. No contractions, no idioms, no complex grammar.\n"
        "- Ask only yes/no or one-word-answer questions: 'Do you like dogs?' 'What color?'\n"
        "- Speak very slowly and clearly. Repeat key words."
    ),
    "A": (
        "English level: A1/A2 (beginner).\n"
        "- Use short, simple sentences with common everyday vocabulary.\n"
        "- Tenses: present simple, past simple, 'going to' future.\n"
        "- Topics: school, food, animals, family, daily routine, weather.\n"
        "- Ask simple open questions: 'What did you eat today?' 'Who is your best friend?'\n"
        "- Avoid phrasal verbs, idioms, and irregular past tenses unless they are very common."
    ),
    "B": (
        "English level: B1/B2 (intermediate).\n"
        "- Use natural everyday English with a variety of sentence lengths.\n"
        "- Mix tenses naturally; include modals (can, could, should, would, might).\n"
        "- Introduce new vocabulary with a brief in-sentence explanation when useful.\n"
        "- Topics: hobbies, travel, opinions, future plans, feelings, books, films.\n"
        "- Use some common phrasal verbs and idiomatic expressions."
    ),
    "C1": (
        "English level: C1 (advanced).\n"
        "- Use rich, varied grammar: conditionals, passive voice, perfect tenses, "
        "embedded clauses.\n"
        "- Use a wide vocabulary including idiomatic expressions; explain them naturally "
        "if they come up.\n"
        "- Engage with more abstract topics: opinions, hypotheticals, comparisons, "
        "light current events.\n"
        "- Challenge the child with occasional sophisticated vocabulary in context."
    ),
    "C2": (
        "English level: C2 (mastery / near-native).\n"
        "- Use the full range of English grammar with natural, fluent sentences.\n"
        "- Use idioms, collocations, and nuanced vocabulary freely.\n"
        "- Engage with complex topics: logic, argumentation, creativity, nuance, humour.\n"
        "- Speak exactly as you would to a highly proficient English speaker.\n"
        "- Introduce rare or interesting words and phrases naturally."
    ),
}


def instructions_for(level: str) -> str:
    """Return the system-prompt addition for *level*, or '' for unknown levels."""
    return LEVEL_INSTRUCTIONS.get(level, "")
