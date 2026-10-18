# lateReferrers for glibc (design §2.9, §11.3): for each late-bound output, the
# sibling outputs that reference it, transitively.  Generated from the
# reference graph Nix registered for the nixpkgs-faithful S5 split
# (docs/research/nix-native/experiments/E4.md); the partitioner verifies it
# (an incomplete list is a build error), so it is static and checked.
#   common: langpacks whose LC_CTYPE is a symlink to common's C.utf8/LC_CTYPE
#           (identical files grouped by the spec); the other langpacks ship
#           their own LC_CTYPE and do not reference common
#   nss_db: nss_devel (libnss_db.so -> nss_db's libnss_db.so.2)
#   utils, benchtests: nothing references them
{
  benchtests = [ ];
  common = [
    "langpack_aa" "langpack_af" "langpack_agr" "langpack_ak" "langpack_an" "langpack_ar"
    "langpack_ast" "langpack_ayc" "langpack_be" "langpack_bem" "langpack_ber"
    "langpack_bg" "langpack_bhb" "langpack_bi" "langpack_bo" "langpack_br" "langpack_bs"
    "langpack_byn" "langpack_ca" "langpack_ce" "langpack_chr" "langpack_crh"
    "langpack_cs" "langpack_csb" "langpack_cv" "langpack_cy" "langpack_dv" "langpack_dz"
    "langpack_el" "langpack_en" "langpack_es" "langpack_et" "langpack_eu" "langpack_ff"
    "langpack_fi" "langpack_fil" "langpack_fr" "langpack_fur" "langpack_fy"
    "langpack_ga" "langpack_gd" "langpack_gez" "langpack_gl" "langpack_gv" "langpack_ha"
    "langpack_he" "langpack_hif" "langpack_ht" "langpack_hy" "langpack_ia" "langpack_id"
    "langpack_ig" "langpack_ik" "langpack_is" "langpack_it" "langpack_iu" "langpack_ka"
    "langpack_kab" "langpack_kk" "langpack_km" "langpack_ks" "langpack_kv" "langpack_kw"
    "langpack_ky" "langpack_lg" "langpack_li" "langpack_lij" "langpack_ln" "langpack_lo"
    "langpack_lt" "langpack_lv" "langpack_mai" "langpack_mg" "langpack_mhr"
    "langpack_mi" "langpack_miq" "langpack_mjw" "langpack_mk" "langpack_ms"
    "langpack_mt" "langpack_nan" "langpack_nds" "langpack_ne" "langpack_nhn"
    "langpack_niu" "langpack_nl" "langpack_nr" "langpack_oc" "langpack_om" "langpack_os"
    "langpack_pap" "langpack_pl" "langpack_pt" "langpack_quz" "langpack_rif"
    "langpack_ru" "langpack_rw" "langpack_sa" "langpack_sah" "langpack_sc" "langpack_sd"
    "langpack_se" "langpack_sgs" "langpack_shn" "langpack_shs" "langpack_si"
    "langpack_sk" "langpack_sl" "langpack_sm" "langpack_so" "langpack_sq" "langpack_ss"
    "langpack_ssy" "langpack_st" "langpack_su" "langpack_sw" "langpack_syr"
    "langpack_szl" "langpack_tg" "langpack_th" "langpack_the" "langpack_ti"
    "langpack_tig" "langpack_tl" "langpack_tn" "langpack_to" "langpack_tpi"
    "langpack_ts" "langpack_tt" "langpack_unm" "langpack_ur" "langpack_ve" "langpack_wo"
    "langpack_xh" "langpack_yo" "langpack_yuw" "langpack_zgh" "langpack_zu"
  ];
  nss_db = [
    "nss_devel"
  ];
  utils = [ ];
}
