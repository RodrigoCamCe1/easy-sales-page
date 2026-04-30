// Navbar scroll effect
const navbar = document.getElementById('navbar');
window.addEventListener('scroll', () => {
  if (window.scrollY > 20) {
    navbar.classList.add('scrolled');
  } else {
    navbar.classList.remove('scrolled');
  }
}, { passive: true });

// Scroll animations (general)
const animatedElements = document.querySelectorAll('.animate-on-scroll, .footer-reveal');
const observer = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      entry.target.classList.add('visible');
    } else {
      entry.target.classList.remove('visible');
    }
  });
}, { threshold: 0.1, rootMargin: '0px 0px -60px 0px' });

animatedElements.forEach(el => observer.observe(el));

// Feature cards — enter early, exit when fully out of viewport
const featureCards = document.querySelectorAll('.feature-card');

// Enter observer: triggers early (80px before entering viewport)
const featureEnterObserver = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      entry.target.classList.add('visible');
    }
  });
}, { threshold: 0.05, rootMargin: '0px 0px 80px 0px' });

// Exit observer: removes visible when card leaves the viewport
const featureExitObserver = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (!entry.isIntersecting) {
      entry.target.classList.remove('visible');
    }
  });
}, { threshold: 0, rootMargin: '0px 0px 0px 0px' });

featureCards.forEach(card => {
  featureEnterObserver.observe(card);
  featureExitObserver.observe(card);
});

function findLatestAsset(releases, matcher) {
  for (const release of releases) {
    const assets = Array.isArray(release.assets) ? release.assets : [];
    const asset = assets.find(matcher);
    if (asset) return { release, asset };
  }
  return null;
}

function extractDisplayVersion(match) {
  if (!match) return null;
  const assetName = match.asset && match.asset.name ? match.asset.name : '';
  const assetVersion = assetName.match(/(\d+\.\d+\.\d+)/);
  if (assetVersion) return assetVersion[1];
  if (match.release && match.release.tag_name) {
    return match.release.tag_name.replace(/^v/, '');
  }
  return null;
}

// Dynamic version from GitHub releases (optional, graceful fallback)
async function fetchLatestVersion() {
  try {
    const res = await fetch('https://api.github.com/repos/RodrigoCamCe1/easy-sales-page/releases');
    if (!res.ok) return;
    const releases = await res.json();
    if (!Array.isArray(releases)) return;

    const windowsMatch = findLatestAsset(releases, a => a.name.toLowerCase().endsWith('.exe'));
    const macMatch = findLatestAsset(releases, a => {
      const name = a.name.toLowerCase();
      return name.endsWith('.zip') && (name.includes('mac') || name.includes('osx'));
    });

    if (windowsMatch && windowsMatch.asset.browser_download_url) {
      const btn = document.getElementById('download-btn-windows');
      if (btn) btn.href = windowsMatch.asset.browser_download_url;
      const version = extractDisplayVersion(windowsMatch);
      if (version) {
        document.querySelectorAll('.version-tag-windows').forEach(el => {
          el.textContent = 'v' + version;
        });
      }
    }
    if (macMatch && macMatch.asset.browser_download_url) {
      const btn = document.getElementById('download-btn-macos');
      if (btn) btn.href = macMatch.asset.browser_download_url;
      const version = extractDisplayVersion(macMatch);
      if (version) {
        document.querySelectorAll('.version-tag-macos').forEach(el => {
          el.textContent = 'v' + version;
        });
      }
    }
  } catch (_) {
    // Silently ignore — static fallback values are already set in HTML
  }
}

fetchLatestVersion();
