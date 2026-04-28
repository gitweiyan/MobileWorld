#!/usr/bin/env bash
set -euo pipefail
#
# Publish MP4 trajectory videos to MAI-UI-blog for GitHub Pages hosting.
#
# Usage:
#   ./site/publish_videos.sh site/trajs/*.mp4
#
# After publishing, regenerate .json.gz files with:
#   uv run python site/bundle_trajs.py <traj_dir> -o site/trajs/<model>.json.gz \
#     --with-screenshots \
#     --video-base-url https://tongyi-mai.github.io/MAI-UI-blog/MobileWorld/trajs

BLOG_REPO="git@github.com:Tongyi-MAI/MAI-UI-blog.git"
DEST_DIR="site/MobileWorld/trajs"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <mp4-files...>"
    echo "Example: $0 site/trajs/*.mp4"
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Cloning $BLOG_REPO ..."
git clone --depth 1 "$BLOG_REPO" "$TMPDIR" 2>&1 | tail -1

mkdir -p "$TMPDIR/$DEST_DIR"
for f in "$@"; do
    echo "Copying $(basename "$f") ($(du -h "$f" | cut -f1))"
    cp "$f" "$TMPDIR/$DEST_DIR/"
done

cd "$TMPDIR"
git add "$DEST_DIR"

if git diff --cached --quiet; then
    echo "No changes to commit."
    exit 0
fi

git commit -m "Update MobileWorld trajectory videos"
git push origin main 2>&1
echo "Done. Videos will be available at:"
echo "  https://tongyi-mai.github.io/MAI-UI-blog/MobileWorld/trajs/"
