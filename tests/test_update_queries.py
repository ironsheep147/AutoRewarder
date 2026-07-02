import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import update_queries


def write_queries(path, queries):
    path.write_text(json.dumps({"queries": queries}, indent=4), encoding="utf-8")


def read_queries(path):
    return json.loads(path.read_text(encoding="utf-8"))["queries"]


class FakeDataFrame:
    def __init__(self, rows):
        self._rows = rows
        self.empty = not bool(rows)

    def to_dict(self, orient):
        if orient != "records":
            raise AssertionError(f"unexpected orient: {orient}")
        return list(self._rows)


class UpdateQueriesTests(unittest.TestCase):
    def test_extracts_and_cleans_trend_breakdowns(self):
        rows = [
            {"Trend breakdown": "Taylor Swift, Chiefs-Ravens, NASA & Space"},
            {
                "trend_breakdown": [
                    "O'Brien",
                    "can’t stop",
                    "C++",
                    "Pokémon",
                    "clean-query",
                ]
            },
        ]

        queries = update_queries.extract_queries_from_rows(rows)

        self.assertEqual(
            queries,
            [
                "Taylor Swift",
                "Chiefs-Ravens",
                "NASA & Space",
                "O'Brien",
                "C++",
                "clean-query",
            ],
        )

    def test_extracts_pytrends_modern_query_fields(self):
        rows = [
            {"entityNames": ["NBA Finals", "Celtics-Lakers", "C++"]},
            {"title": "Google Trends"},
        ]

        queries = update_queries.extract_queries_from_rows(rows)

        self.assertEqual(
            queries, ["NBA Finals", "Celtics-Lakers", "C++", "Google Trends"]
        )

    def test_parses_google_trends_csv_rows(self):
        csv_text = (
            "Trends,Search volume,Trend breakdown\n"
            '"nba finals","1M+","Celtics, Lakers, C++"\n'
            '"weather","500K+","NASA & Space, O\'Brien"\n'
        )

        rows = update_queries.parse_trends_csv(csv_text)

        self.assertEqual(
            rows,
            [
                {
                    "Trends": "nba finals",
                    "Search volume": "1M+",
                    "Trend breakdown": "Celtics, Lakers, C++",
                },
                {
                    "Trends": "weather",
                    "Search volume": "500K+",
                    "Trend breakdown": "NASA & Space, O'Brien",
                },
            ],
        )

    def test_combine_preserves_existing_generated_queries(self):
        with tempfile.TemporaryDirectory() as tmp:
            queries_path = Path(tmp) / "queries.json"
            base_path = Path(tmp) / "queries.base.json"
            write_queries(queries_path, ["old generated"])
            write_queries(base_path, ["NASA & Space", "baseline query"])

            result = update_queries.update_queries_file(
                queries_path,
                base_path,
                ["nasa & space", "new trend"],
                mode="combine",
            )

            self.assertEqual(
                read_queries(queries_path),
                ["new trend", "old generated", "NASA & Space", "baseline query"],
            )
            self.assertEqual(result.added_count, 1)
            self.assertFalse(result.created_base)

    def test_combine_dedupes_final_output_after_merging_trends_and_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            queries_path = Path(tmp) / "queries.json"
            base_path = Path(tmp) / "queries.base.json"
            write_queries(queries_path, ["old generated"])
            write_queries(
                base_path,
                ["NASA & Space", "baseline query", "nasa & space", "BASELINE QUERY"],
            )

            result = update_queries.update_queries_file(
                queries_path,
                base_path,
                ["new trend", "baseline query", "NEW TREND"],
                mode="combine",
            )

            self.assertEqual(
                read_queries(queries_path),
                ["new trend", "old generated", "NASA & Space", "baseline query"],
            )
            self.assertEqual(result.total_count, 4)
            self.assertEqual(result.added_count, 1)

    def test_first_update_creates_base_from_current_queries(self):
        with tempfile.TemporaryDirectory() as tmp:
            queries_path = Path(tmp) / "queries.json"
            base_path = Path(tmp) / "queries.base.json"
            write_queries(queries_path, ["original query"])

            result = update_queries.update_queries_file(
                queries_path,
                base_path,
                ["fresh trend"],
                mode="combine",
            )

            self.assertEqual(read_queries(base_path), ["original query"])
            self.assertEqual(
                read_queries(queries_path), ["fresh trend", "original query"]
            )
            self.assertTrue(result.created_base)

    def test_replace_mode_writes_only_trends(self):
        with tempfile.TemporaryDirectory() as tmp:
            queries_path = Path(tmp) / "queries.json"
            base_path = Path(tmp) / "queries.base.json"
            write_queries(queries_path, ["original query"])

            update_queries.update_queries_file(
                queries_path,
                base_path,
                ["fresh trend"],
                mode="replace",
            )

            self.assertEqual(read_queries(queries_path), ["fresh trend"])

    def test_reset_restores_base_queries(self):
        with tempfile.TemporaryDirectory() as tmp:
            queries_path = Path(tmp) / "queries.json"
            base_path = Path(tmp) / "queries.base.json"
            write_queries(queries_path, ["generated query"])
            write_queries(base_path, ["original query"])

            restored = update_queries.reset_queries_file(queries_path, base_path)

            self.assertEqual(restored, 1)
            self.assertEqual(read_queries(queries_path), ["original query"])

    def test_fetch_failure_leaves_queries_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            queries_path = Path(tmp) / "queries.json"
            base_path = Path(tmp) / "queries.base.json"
            write_queries(queries_path, ["original query"])

            with patch(
                "update_queries.fetch_trend_rows", side_effect=RuntimeError("boom")
            ):
                exit_code = update_queries.main(
                    [
                        "update",
                        "--queries-file",
                        str(queries_path),
                        "--base-file",
                        str(base_path),
                    ]
                )

            self.assertEqual(exit_code, 1)
            self.assertEqual(read_queries(queries_path), ["original query"])
            self.assertFalse(base_path.exists())

    def test_main_defaults_to_update_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            queries_path = Path(tmp) / "queries.json"
            base_path = Path(tmp) / "queries.base.json"
            write_queries(queries_path, ["original query"])

            with patch(
                "update_queries.fetch_trend_rows",
                return_value=[{"Trend breakdown": "fresh trend"}],
            ):
                exit_code = update_queries.main(
                    ["--queries-file", str(queries_path), "--base-file", str(base_path)]
                )

            self.assertEqual(exit_code, 0)
            self.assertEqual(
                read_queries(queries_path), ["fresh trend", "original query"]
            )

    def test_fetch_trend_rows_uses_browser_csv_download(self):
        downloader = Mock(return_value='Trend breakdown\n"one, two"\n')

        rows = update_queries.fetch_trend_rows(
            browser_csv_downloader=downloader,
        )

        self.assertEqual(rows, [{"Trend breakdown": "one, two"}])
        downloader.assert_called_once_with(
            geo="US", hours=168, browser="edge", headless=True, timeout=45
        )

    def test_fetch_trend_rows_reports_browser_csv_download_failure(self):
        downloader = Mock(side_effect=RuntimeError("button missing"))

        with self.assertRaisesRegex(RuntimeError, "browser CSV download failed"):
            update_queries.fetch_trend_rows(browser_csv_downloader=downloader)

        downloader.assert_called_once()


if __name__ == "__main__":
    unittest.main()
