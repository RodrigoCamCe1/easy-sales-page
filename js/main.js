// Navbar scroll effect
const navbar = document.getElementById('navbar');
window.addEventListener('scroll', () => {
  if (window.scrollY > 20) {
    navbar.classList.add('scrolled');
  } else {
    navbar.classList.remove('scrolled');
  }
}, { passive: true });

// Scroll animations
const animatedElements = document.querySelectorAll('.animate-on-scroll, .stagger-in, .footer-reveal');
const observer = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      entry.target.classList.add('visible');
      observer.unobserve(entry.target);
    }
  });
}, { threshold: 0.1, rootMargin: '0px 0px -60px 0px' });

animatedElements.forEach(el => observer.observe(el));

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
