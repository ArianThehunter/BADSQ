-- 0020: 3.1.1, 5.1.1 and SR.3 each had is_instruction_replayable = false while
-- every sibling item in their subdomain had true -- single-item drift, not a
-- deliberate per-item rule. No instruction audio exists anywhere yet, so this
-- flag has no runtime effect today; normalizing now so behavior stays uniform
-- per subdomain once instruction audio is uploaded.
update items set is_instruction_replayable = true
where item_code in ('3.1.1', '5.1.1', 'SR.3');
