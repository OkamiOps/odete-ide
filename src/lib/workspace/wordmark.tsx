import { useChrome } from "@/lib/workspace/chrome";
import { themeById } from "@/lib/workspace/themes";

type Props = {
  className?: string;
  alt?: string;
  force?: "dark" | "light";
};

export function OdeteWordmark({ className, alt = "Odete", force }: Props) {
  const theme = useChrome((s) => s.theme);
  const dark = force ? force === "dark" : themeById(theme).dark;
  const src = dark ? "/brand/odete-wordmark.png?v=10" : "/brand/odete-wordmark-light.png?v=10";
  return <img className={className} src={src} alt={alt} />;
}
