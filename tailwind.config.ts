import type { Config } from 'tailwindcss';

const config: Config = {
  content: ['./src/app/**/*.{ts,tsx}', './src/components/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        base: {
          900: '#050a08',
          800: '#070f0c',
          700: '#0b1512',
          600: '#101d18',
          500: '#16261f',
        },
        line: {
          DEFAULT: 'rgba(148, 220, 189, 0.10)',
          strong: 'rgba(148, 220, 189, 0.20)',
        },
        ink: {
          DEFAULT: '#e8f3ee',
          muted: '#9db3aa',
          faint: '#6d827a',
        },
        clover: {
          50: '#eafaf1',
          200: '#a7e9c8',
          300: '#6fd9a8',
          400: '#3dc78c',
          500: '#22b177',
          600: '#178f60',
          700: '#116e4b',
        },
      },
      fontFamily: {
        sans: ['var(--font-sans)'],
        mono: ['var(--font-mono)'],
      },
      borderRadius: {
        xl: '14px',
        '2xl': '20px',
      },
      transitionTimingFunction: {
        calm: 'cubic-bezier(0.22, 0.61, 0.36, 1)',
      },
      keyframes: {
        'fade-rise': {
          from: { opacity: '0', transform: 'translateY(6px)' },
          to: { opacity: '1', transform: 'none' },
        },
        'pulse-soft': {
          '0%, 100%': { opacity: '1' },
          '50%': { opacity: '0.45' },
        },
      },
      animation: {
        'fade-rise': 'fade-rise 480ms cubic-bezier(0.22, 0.61, 0.36, 1) both',
        'pulse-soft': 'pulse-soft 2.4s cubic-bezier(0.22, 0.61, 0.36, 1) infinite',
      },
    },
  },
  plugins: [],
};

export default config;
