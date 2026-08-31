/**
 * Landing page — the front door for both audiences this platform serves.
 * Deliberately simple: two clearly-labelled paths (participant / researcher)
 * and nothing else. The Phase 0 diagnostic checks that used to live at `/`
 * moved to `#/status` rather than being deleted — still useful for verifying
 * a deployment, just not the first thing anyone should see.
 */
import './landing.css';

export default function LandingPage() {
  return (
    <main className="landing-shell">
      <div className="landing-header">
        <h1>
          BADSQ <span lang="bn">— বাংলা ডিসলেক্সিয়া স্ক্রিনিং</span>
        </h1>
        <p className="landing-sub">
          A short, audio-guided screening tool that helps identify early signs of dyslexia in
          Bangla-speaking students aged 12–14.
        </p>
      </div>

      <div className="landing-cards">
        <a className="landing-card" href="#/test">
          <span className="landing-card-icon" aria-hidden="true">
            📝
          </span>
          <h2 lang="bn">শিক্ষার্থী</h2>
          <p className="muted">Student — start the screening test</p>
          <span className="landing-card-cta">শুরু করো (Start) →</span>
        </a>

        <a className="landing-card" href="#/admin">
          <span className="landing-card-icon" aria-hidden="true">
            🔬
          </span>
          <h2 lang="bn">গবেষক</h2>
          <p className="muted">Researcher — sign in to manage items, ratings, and data</p>
          <span className="landing-card-cta">Sign in →</span>
        </a>
      </div>

      <p className="landing-footer">
        <a href="#/status">System status</a>
      </p>
    </main>
  );
}
