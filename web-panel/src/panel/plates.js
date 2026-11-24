// FreeNova panel — where the artwork of the Winterfest pages lives.
//
// The plates the owner approved are the reference for every page
// (docs/design/refs/winterfest/*.png). A page paints its plate ONCE, whole, at
// the plate's own size, and cuts clean slices of it ("strips") to cover the
// sample values it has to replace; the page's own text goes on those strips.
// Nothing is redrawn by hand and nothing is generated unless the plate has no
// such piece, and then it is recorded in ASSET-MANIFEST.json with its licence.
//
// The /dashboard.png URL predates this module and is kept for that reason: the
// plate is served from assets/dashboard.png (Cloudflare [assets] binding on the
// Worker, assetsDir on the local runner), and a path is the only thing the CSS
// needs.
export const PLATE_URL = {
  dashboard: "/dashboard.png",
  advent: "/plates/11-advent.png",
  levels: "/plates/13-levels.png",
  admin: "/plates/14-admin.png"
}

/** The url for one plate, or the dashboard plate for an unknown key. */
export function plateUrl(key) { return PLATE_URL[key] || PLATE_URL.dashboard }

/**
 * The nu nito face the plates use, one variable file (OFL-1.1, licence file next
 * to it). Served from assets/fonts on both runtimes.
 */
export const FONT_FACE = `@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}`

/**
 * The one-screen stage rule every Winterfest page shares: a fixed W x H stage,
 * scaled as a whole by min(vw/W, vh/H, 1) and letterboxed. Never a reflow and
 * never a scrollbar - the CSS `scale:` line is the same formula for a client
 * with no script, and the script sets the exact translate+scale on top.
 */
export function stageCss(w, h, bg) {
  return `*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;background:${bg};overflow:hidden}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,'Arial',sans-serif;-webkit-font-smoothing:antialiased}
#stage{position:absolute;left:0;top:0;width:${w}px;height:${h}px;background:${bg};
  overflow:hidden;will-change:transform;transform-origin:0 0;color:#fff;
  scale:min(calc(100vw / ${w}), calc(100vh / ${h}), 1)}`
}

/** The script that fits the fixed stage to the viewport and flags no-scroll. */
export function stageScript(w, h) {
  return `(function(){
  var st=document.getElementById('stage');if(!st)return;
  var fit=function(){
    var vw=window.innerWidth,vh=window.innerHeight;
    var s=Math.min(vw/${w},vh/${h},1);
    st.style.transform='translate('+((vw-${w}*s)/2)+'px,'+((vh-${h}*s)/2)+'px) scale('+s+')';
    st.style.scale='1';
    st.setAttribute('data-scale',s.toFixed(4));
    st.setAttribute('data-noscroll', String(
      document.documentElement.scrollWidth <= window.innerWidth &&
      document.documentElement.scrollHeight <= window.innerHeight));
  };
  fit();window.addEventListener('resize',fit);
})();`
}

/**
 * One background panel of a plate. `src` is the plate url and the background
 * rule slices it to `sw`/`sh`; the box is where the slice is painted.
 */
export function stripCss(name, src, sx, sy, sw, sh, x, y, w, h) {
  return `.strip-${name}{position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
    `background-image:url(${src});background-repeat:no-repeat;` +
    `background-position:${-sx}px ${-sy}px;background-size:${sw}px ${sh}px}`
}

/**
 * The three bottom cards' title line: the clean inner of the "Your Progress" card
 * (left of its gift icon's box, on the card's own background). On a plate that
 * does not have that card, the same coordinates land on its nearest equal
 * surface, which is the same rule every other cut follows.
 */
export const CARD_TITLE_SLICE = { x: 400, y: 806, w: 60, h: 20 }
