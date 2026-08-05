/**
 * The Clovyre mark.
 *
 * Drawn rather than borrowed from an icon set. A stock sparkle is the most
 * recognisable "generated app" signature there is, and a brand should not be
 * the same glyph a thousand other products reach for.
 *
 * One heart-shaped leaflet, rotated four times about the centre. The notch
 * faces outward and the point meets the middle, which is what separates a
 * clover from a flower — four circles would read as the latter. No stem: at
 * 15px there is no room for one, and the four-leaf arrangement carries the
 * meaning on its own.
 */

// A single leaflet, pointing up, tip at the centre of the 24 grid.
const LEAF =
  'M12 13.4C12 9 8.2 9.2 7.1 6.5 6.2 4.2 8.4 1.9 10.4 3.1'
  + 'c.8.5 1.3 1.2 1.6 2.1.3-.9.8-1.6 1.6-2.1 2-1.2 4.2 1.1 3.3 3.4'
  + '-1.1 2.7-4.9 2.5-4.9 6.9Z';

export function CloverMark({ size = 20, className = '', title }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      className={className}
      role={title ? 'img' : 'presentation'}
      aria-hidden={title ? undefined : 'true'}
    >
      {title && <title>{title}</title>}
      <path d={LEAF} />
      <path d={LEAF} transform="rotate(90 12 12)" />
      <path d={LEAF} transform="rotate(180 12 12)" />
      <path d={LEAF} transform="rotate(270 12 12)" />
    </svg>
  );
}

export default CloverMark;
