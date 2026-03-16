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

// Dynamic version from GitHub releases (optional, graceful fallback)
async function fetchLatestVersion() {
  try {
    const res = await fetch('https://api.github.com/repos/jfprsmcp/easy-sales-ia/releases/latest');
    if (!res.ok) return;
    const data = await res.json();
    const version = data.tag_name ? data.tag_name.replace(/^v/, '') : null;
    const asset = data.assets && data.assets.find(a => a.name.endsWith('.exe'));
    if (version) {
      document.querySelectorAll('.version-tag').forEach(el => {
        el.textContent = 'v' + version;
      });
    }
    if (asset && asset.browser_download_url) {
      const btn = document.getElementById('download-btn');
      if (btn) btn.href = asset.browser_download_url;
    }
  } catch (_) {
    // Silently ignore — static fallback values are already set in HTML
  }
}

fetchLatestVersion();
