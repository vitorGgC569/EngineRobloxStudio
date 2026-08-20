"""The design compiler.

This is the only layer whose output has no verifiable right answer. Everything
else can be checked against something -- a curve against the shipped
`Progression`, a layout against a device, a catalogue against its own balance
rules. "Is this a good game idea" cannot be.

So the tests are about the two things that *are* checkable.

**It shows its work.** Every field carries STATED, INFERRED or DEFAULTED, and an
inference names the words that produced it. A compiler that hid its defaults
inside its inferences would be confident, unarguable, and the most dangerous
module in the stack.

**The result holds together.** A design that reads beautifully and produces an
incoherent model has failed at the only thing this layer can be held to.
"""

from __future__ import annotations

import unittest

from rqe.design import (
    DEFAULTED,
    INFERRED,
    STATED,
    DesignError,
    analyse,
    compile_brief,
)
from rqe.recipes import check, conforms

#: The document's own example sentence, and two more in the languages briefs
#: actually arrive in.
BRIEFS = {
    "ocean-lab": "Tycoon de laboratorio submarino com exploracao, coleta de "
                 "criaturas e automacao.",
    "gate-siege": "A tower defense where you hold a temple gate through waves, "
                  "with a shop and a leaderboard.",
    "card-vault": "Colecao de cartas com gacha, troca entre jogadores e sessoes "
                  "de 10 minutos.",
}


class TestAnalysis(unittest.TestCase):
    def test_an_empty_brief_is_refused(self):
        with self.assertRaises(DesignError):
            analyse("   ")

    def test_genre_signals_are_read_in_both_languages(self):
        """Briefs arrive in Portuguese and English interchangeably, and a
        compiler that only read one would default silently on half of them."""

        portuguese = analyse("Tycoon com automacao e producao.")
        english = analyse("A tycoon with automation and production.")
        self.assertEqual(portuguese.genre, "tycoon")
        self.assertEqual(english.genre, "tycoon")

    def test_the_evidence_is_the_words_from_the_brief(self):
        analysis = analyse("Tower defense com ondas e cerco.")
        self.assertEqual(analysis.genre, "tower_defense")
        self.assertTrue(analysis.genre_scores["tower_defense"])

    def test_a_place_named_twice_in_two_languages_counts_once(self):
        """A flat word list produced the theme 'lab laboratorio' -- the same
        concept twice, read back as if it were two places."""

        analysis = analyse("Um laboratorio submarino, a lab under the sea.")
        self.assertEqual(analysis.places.count("lab"), 1)

    def test_a_session_length_is_read_from_the_brief(self):
        self.assertEqual(analyse("Sessoes de 10 minutos.").session_minutes, 10.0)
        self.assertEqual(analyse("Sessions of 2 hours.").session_minutes, 120.0)

    def test_a_named_resource_is_read_as_product_identity(self):
        analysis = analyse("Defenda o sino e recolha brasas.")
        self.assertEqual(analysis.currency, ("embers", "Embers"))
        self.assertIn("brasas", analysis.currency_evidence)

    def test_an_ambiguous_genre_is_reported_rather_than_resolved_silently(self):
        """Picking one without saying so is how a brief becomes a game nobody
        asked for."""

        analysis = analyse("cartas e corrida")
        self.assertTrue(analysis.ambiguities)

    def test_a_brief_with_no_genre_signal_says_it_guessed(self):
        analysis = analyse("Something fun for friends.")
        self.assertTrue(any("guess" in item for item in analysis.ambiguities))


class TestProvenance(unittest.TestCase):
    """The property that makes a generated design arguable."""

    def test_every_decision_declares_how_it_got_there(self):
        document = compile_brief(BRIEFS["ocean-lab"], id="probe")
        for decision in document.decisions:
            self.assertIn(decision.provenance, (STATED, INFERRED, DEFAULTED),
                          decision.field)

    def test_an_inference_names_the_words_that_produced_it(self):
        document = compile_brief(BRIEFS["ocean-lab"], id="probe")
        inferred = [d for d in document.decisions if d.provenance == INFERRED]
        self.assertTrue(inferred)
        for decision in inferred:
            self.assertTrue(decision.evidence or decision.note, decision.field)

    def test_a_default_carries_a_reason_instead_of_evidence(self):
        """Empty evidence is exactly what makes a default visible."""

        document = compile_brief(BRIEFS["ocean-lab"], id="probe")
        for decision in document.decisions:
            if decision.provenance == DEFAULTED:
                self.assertEqual(decision.evidence, ())
                self.assertTrue(decision.note.strip(), decision.field)

    def test_what_the_caller_states_is_not_re_derived(self):
        """A designer who names the genre has settled it; re-deriving would be
        the compiler arguing with the person it works for."""

        document = compile_brief("Cartas e gacha.", id="probe", genre="racing")
        self.assertEqual(document.model.genre, "racing")
        self.assertEqual(document.decision("genre").provenance, STATED)

    def test_the_pitch_is_the_brief_verbatim(self):
        """Paraphrasing would put words in the designer's mouth."""

        document = compile_brief(BRIEFS["gate-siege"], id="probe")
        self.assertEqual(document.model.pitch, BRIEFS["gate-siege"])

    def test_the_defaulted_fields_are_listed_together(self):
        document = compile_brief(BRIEFS["ocean-lab"], id="probe")
        self.assertIn("monetization", document.defaulted)


class TestTheResultHoldsTogether(unittest.TestCase):
    """The one thing this layer can be held to."""

    def test_every_brief_compiles_to_a_coherent_model(self):
        for game_id, brief in BRIEFS.items():
            document = compile_brief(brief, id=game_id)
            self.assertTrue(document.model.coherent,
                            f"{game_id}: {document.model.problems()}")

    def test_every_brief_compiles_to_a_model_that_conforms_to_its_genre(self):
        for game_id, brief in BRIEFS.items():
            document = compile_brief(brief, id=game_id)
            self.assertTrue(conforms(document.model),
                            f"{game_id}: {check(document.model)}")

    def test_the_briefs_produce_different_genres(self):
        """If they did not, the reading would be doing nothing."""

        genres = {compile_brief(brief, id=key).model.genre
                  for key, brief in BRIEFS.items()}
        self.assertEqual(len(genres), 3)

    def test_a_mechanic_in_the_brief_reaches_the_loop(self):
        document = compile_brief(BRIEFS["ocean-lab"], id="probe")
        self.assertIn("explore", document.model.core_loop)

    def test_a_mechanic_in_the_brief_reaches_the_systems(self):
        document = compile_brief(BRIEFS["card-vault"], id="probe")
        self.assertIn("gacha", document.model.systems)
        self.assertIn("trading", document.model.systems)

    def test_a_session_length_in_the_brief_reaches_the_progression(self):
        document = compile_brief(BRIEFS["card-vault"], id="probe")
        self.assertEqual(document.model.progression.session_minutes, 10.0)

    def test_a_named_resource_replaces_generic_cash_in_the_model(self):
        document = compile_brief(
            "Tower defense de terror: defenda o sino, ganhe brasas e construa lanternas.",
            id="last-vigil",
            genre="tower_defense",
        )
        self.assertEqual(document.model.currencies[0].id, "embers")
        self.assertEqual(document.model.currencies[0].display_name, "Embers")
        self.assertEqual(document.decision("currency").provenance, INFERRED)

    def test_a_zoned_topology_always_gets_zones(self):
        """A hub-and-zones world with no zones is a hub with nowhere to go."""

        document = compile_brief(BRIEFS["card-vault"], id="probe")
        self.assertTrue(document.model.zones)

    def test_the_document_compiles_all_the_way_to_a_plan(self):
        """The design has to reach the pipeline, not just read well.

        Scaffolded first, because a plan referencing definition files that do
        not exist is a plan that cannot detect them changing."""

        import shutil
        from pathlib import Path
        from tempfile import TemporaryDirectory

        from rqe.ir.compiler import compile_model
        from rqe.ir.scaffold import scaffold_project

        repo = Path(__file__).resolve().parents[1]
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "schemas").mkdir()
            for schema in (repo / "schemas").glob("*.json"):
                shutil.copyfile(schema, root / "schemas" / schema.name)
            (root / "quality").mkdir()
            shutil.copyfile(
                repo / "quality" / "probe-registry.v1.json",
                root / "quality" / "probe-registry.v1.json",
            )

            document = compile_brief(BRIEFS["gate-siege"], id="probe")
            scaffold_project(document.model, root=root)
            result = compile_model(document.model, root=root)
            self.assertTrue(result["plan"]["projects"][0]["tasks"])

    def test_compiling_before_scaffolding_says_to_scaffold(self):
        """Otherwise this surfaced as a schema error about a missing sha256,
        which says nothing about what to do."""

        from pathlib import Path
        from tempfile import TemporaryDirectory

        from rqe.ir.compiler import MissingDefinition, compile_model

        document = compile_brief(BRIEFS["gate-siege"], id="probe")
        with TemporaryDirectory() as directory:
            with self.assertRaises(MissingDefinition) as caught:
                compile_model(document.model, root=Path(directory))
        self.assertIn("game_new", str(caught.exception))


class TestDownstream(unittest.TestCase):
    def test_the_design_names_the_screens_its_systems_imply(self):
        document = compile_brief(BRIEFS["gate-siege"], id="probe")
        payload = document.to_dict()
        self.assertIn("shop", payload["screens"])

    def test_the_report_carries_the_ambiguities(self):
        document = compile_brief("Something fun.", id="probe")
        self.assertTrue(document.to_dict()["ambiguities"])

    def test_the_report_says_where_disagreement_belongs(self):
        payload = compile_brief(BRIEFS["ocean-lab"], id="probe").to_dict()
        self.assertIn("disagreement belongs", payload["note"])


if __name__ == "__main__":
    unittest.main()
