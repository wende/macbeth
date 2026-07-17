import Nav from "../sections/Nav";
import Hero from "../sections/Hero";
import Features from "../sections/Features";
import Demo from "../sections/Demo";
import Permissions from "../sections/Permissions";
import Faq from "../sections/Faq";
import Cta from "../sections/Cta";
import Footer from "../sections/Footer";

export default function Home() {
  return (
    <div className="min-h-screen bg-white">
      <Nav />
      <main>
        <Hero />
        <Demo />
        <Features />
        <Permissions />
        <Faq />
        <Cta />
      </main>
      <Footer />
    </div>
  );
}
