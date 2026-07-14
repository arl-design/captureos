import { useEffect, useState } from 'react';

import { Admin } from './admin/Admin';
import { Booth } from './booth/Booth';
import { Gallery } from './gallery/Gallery';

// Hash routing keeps the kiosk build free of any server-side route
// configuration: the touch panel loads /#/ and the wall display /#/gallery.
function useHashRoute(): string {
  const [route, setRoute] = useState(() => window.location.hash.slice(1) || '/');
  useEffect(() => {
    const onChange = () => setRoute(window.location.hash.slice(1) || '/');
    window.addEventListener('hashchange', onChange);
    return () => window.removeEventListener('hashchange', onChange);
  }, []);
  return route;
}

export default function App() {
  const route = useHashRoute();
  if (route.startsWith('/admin')) return <Admin />;
  if (route.startsWith('/slideshow')) return <Gallery forceMode="slideshow" />;
  if (route.startsWith('/gallery')) return <Gallery />;
  return <Booth />;
}
