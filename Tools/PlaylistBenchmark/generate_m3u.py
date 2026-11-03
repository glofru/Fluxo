#!/usr/bin/env python3
"""Generate a synthetic, realistic IPTV M3U playlist for benchmarking.

Usage: generate_m3u.py OUTPUT [--entries N] [--crlf] [--seed S]
"""
import argparse
import random

COUNTRIES = ["US", "UK", "IT", "DE", "FR", "ES", "BR", "CA", "PT", "NL"]
CATEGORIES = ["News", "Sports", "Movies", "Kids", "Music", "Documentary", "Entertainment", "Series", "Religious", "Local"]
WORDS = ["Prime", "One", "Max", "Plus", "Live", "World", "Gold", "Cinema", "Action", "Family", "Star", "Nova", "Zone", "Classic"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--entries", type=int, default=100_000)
    parser.add_argument("--crlf", action="store_true")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    eol = "\r\n" if args.crlf else "\n"
    groups = [f"{c} | {cat}" for c in COUNTRIES for cat in CATEGORIES]
    groups += [f"{cat}, {c} (HD)" for c in COUNTRIES[:4] for cat in CATEGORIES]  # commas inside quoted values

    with open(args.output, "w", encoding="utf-8", newline="") as out:
        out.write('\ufeff#EXTM3U url-tvg="https://epg.example.com/guide.xml.gz" x-tvg-url="https://epg.example.com/guide.xml.gz"' + eol)
        for i in range(args.entries):
            group = rng.choice(groups)
            words = " ".join(rng.sample(WORDS, rng.randint(1, 3)))
            country = rng.choice(COUNTRIES)
            is_movie = rng.random() < 0.3
            if is_movie:
                name = f"{words} {rng.randint(1970, 2025)}, Part {rng.randint(1, 3)}"  # commas in the title
                url = f"https://provider.example.com:8443/movie/user123/pass456/{100000 + i}.{rng.choice(['mp4', 'mkv'])}"
            else:
                name = f"{country}: {words} {i} {rng.choice(['HD', 'FHD', 'SD', '4K'])}"
                url = f"http://provider.example.com:8080/user123/pass456/{100000 + i}"
            logo = "" if rng.random() < 0.1 else f"https://logos.example.com/images/{country.lower()}/{i}.png"
            if rng.random() < 0.05:
                # Plain EXTINF + EXTGRP style entry without attributes.
                out.write(f"#EXTINF:-1,{name}{eol}#EXTGRP:{group}{eol}{url}{eol}")
                continue
            out.write(
                f'#EXTINF:-1 tvg-id="{words.replace(" ", "").lower()}{i}.{country.lower()}" tvg-name="{name}" '
                f'tvg-logo="{logo}" group-title="{group}",{name}{eol}'
            )
            if rng.random() < 0.1:
                out.write(f"#EXTVLCOPT:http-user-agent=Mozilla/5.0 (Fluxo){eol}")
            out.write(url + eol)


if __name__ == "__main__":
    main()
