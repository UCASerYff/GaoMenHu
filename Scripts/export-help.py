"""Export help articles from the project's README into a build staging folder."""

import argparse
from pathlib import Path
import re


ARTICLES = {
    "Downloads/Recovery.md": "下载资料恢复",
    "Downloads/DataFormat.md": "下载资料与预算",
    "Downloads/Validation.md": "下载功能边界",
    "Mail/OAuthSetup.txt": "邮件授权配置",
}


def export_help(directory, articles):
    readme = Path(__file__).resolve().parents[1] / "README.md"
    sections = re.split(r"(?m)^## ", readme.read_text(encoding="utf-8"))[1:]
    for article in articles:
        title = ARTICLES[article]
        bodies = [section.partition("\n")[2].strip() for section in sections if section.partition("\n")[0] == title]
        if len(bodies) != 1 or not bodies[0]:
            raise ValueError(f"Expected one populated README section: {title}")
        target = directory / article
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.suffix == ".md":
            contents = f"# {title}\n\n{bodies[0]}\n"
        else:
            body = re.sub(r"(?m)^### ", "", bodies[0])
            contents = f"{title}\n\n{body}\n"
        target.write_text(contents, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("articles", nargs="+", choices=ARTICLES)
    options = parser.parse_args()
    export_help(options.directory, options.articles)
