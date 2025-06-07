#!/bin/bash

# Exit on error
set -e

# Check if homebrew-tools submodule exists
if [ ! -d "homebrew-tools" ]; then
    echo "Adding homebrew-tools submodule..."
    git submodule add git@github.com:karpulix/homebrew-tools.git
fi

# Update submodule
echo "Updating submodule..."
git submodule update --init --recursive

# Get current version from macosloginwatcher.sh
CURRENT_VERSION=$(grep 'VERSION=' macosloginwatcher.sh | cut -d'"' -f2)
echo "Current version: $CURRENT_VERSION"

# Parse version components
IFS='.' read -r -a VERSION_PARTS <<< "$CURRENT_VERSION"
MAJOR="${VERSION_PARTS[0]}"
MINOR="${VERSION_PARTS[1]}"
PATCH="${VERSION_PARTS[2]}"

# Increment patch version
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="$MAJOR.$MINOR.$NEW_PATCH"
echo "New version: $NEW_VERSION"

# Update version in macosloginwatcher.sh
sed -i '' "s/VERSION=\"$CURRENT_VERSION\"/VERSION=\"$NEW_VERSION\"/" macosloginwatcher.sh

# Update version and URL in macosloginwatcher.rb in submodule
cd homebrew-tools
git checkout main
git pull origin main
sed -i '' "s/version \"$CURRENT_VERSION\"/version \"$NEW_VERSION\"/" macosloginwatcher.rb
sed -i '' "4s|.*|  url \"https://github.com/karpulix/macosloginwatcher/releases/download/v$NEW_VERSION/macosloginwatcher-$NEW_VERSION.tar.gz\"|" macosloginwatcher.rb
cd ..

# Git operations for main repo
git add macosloginwatcher.sh
git commit -m "version $NEW_VERSION"
git tag -a "v$NEW_VERSION" -m "Release version $NEW_VERSION"
git push origin main
git push origin "v$NEW_VERSION"

# Create release archive
echo "Creating release archive..."
ARCHIVE_NAME="macosloginwatcher-$NEW_VERSION.tar.gz"
tar -czf "$ARCHIVE_NAME" macosloginwatcher.sh

# Calculate SHA256 before uploading
SHA256=$(shasum -a 256 "$ARCHIVE_NAME" | cut -d' ' -f1)
echo "SHA256: $SHA256"

# Create GitHub release with the archive
echo "Creating GitHub release..."
gh release create "v$NEW_VERSION" \
    --title "Release v$NEW_VERSION" \
    --notes "Release version $NEW_VERSION" \
    --generate-notes \
    "$ARCHIVE_NAME"

# Update SHA256 in macosloginwatcher.rb in submodule
cd homebrew-tools
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" macosloginwatcher.rb
git add macosloginwatcher.rb
git commit -m "Update macosloginwatcher to version $NEW_VERSION"
git push origin main
cd ..

# Update main repo with submodule changes
git add homebrew-tools
git commit -m "Update homebrew-tools submodule to version $NEW_VERSION"
git push origin main

# Clean up
rm "$ARCHIVE_NAME"

echo "Release process completed successfully!"
echo "New version: $NEW_VERSION"
echo "SHA256: $SHA256" 