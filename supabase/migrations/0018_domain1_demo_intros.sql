-- 0018: Domain 1 (Short-term Memory) demo/practice-intro content, using the
-- four demo examples given directly in the question-paper changelog (৫-১-৮,
-- ৩-৭-২, ক-ত-প, গ-ফ-খ). Other domains' demo scripts are still not inserted
-- -- their prose didn't survive PDF extraction reliably enough to trust
-- verbatim (see prior session notes); these four are short, literal example
-- sequences typed directly in the changelog, not reconstructed prose, so
-- there was nothing ambiguous to verify here.
insert into domain_intros (domain, subdomain, intro_text, display_order, active)
values
  ('1', '1.1 Digit Span Forward',
   'এখন আমরা কিছু সংখ্যা শুনব। মনোযোগ দিয়ে শুনে ঠিক একই ক্রমে সংখ্যাগুলো লিখবে। যেমন, যদি শোনো ৫-১-৮, তাহলে তুমি লিখবে ৫, তারপর ১, তারপর ৮।',
   10, true),
  ('1', '1.2 Digit Span Backward',
   'এবার সংখ্যাগুলো উল্টো ক্রমে লিখতে হবে। যেমন, যদি শোনো ৩-৭-২, তাহলে তুমি লিখবে ২, তারপর ৭, তারপর ৩।',
   11, true),
  ('1', '1.3 Letter Span Forward',
   'এখন সংখ্যার বদলে অক্ষর শুনবে। শোনা ক্রমেই অক্ষরগুলো বেছে নেবে। যেমন, যদি শোনো ক-ত-প, তাহলে তুমি বেছে নেবে ক, তারপর ত, তারপর প।',
   12, true),
  ('1', '1.4 Letter Span Backward',
   'এবার অক্ষরগুলো উল্টো ক্রমে বেছে নিতে হবে। যেমন, যদি শোনো গ-ফ-খ, তাহলে তুমি বেছে নেবে খ, তারপর ফ, তারপর গ।',
   13, true)
on conflict do nothing;
